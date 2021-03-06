module.exports = (env) ->

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'
  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'
  _ = env.require 'lodash'
  M = env.matcher
  needle = require('needle')

  IcalExpander = require 'ical-expander'

  fs = require 'fs'

  class CalendarPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      @calendars = _.cloneDeep(@config.calendars)
      @scheduledTimeouts = []
      @ongoingEvents = {}

      @updateInterval = if @config.updateInterval? then @config.updateInterval else 3600000 # 1 hour
      scheduleInterval = 10*60*1000

      #currentEvent
      @calendarEventVariableName = "calendar-event"
      @framework.variableManager.waitForInit()
      .then(()=>
        @calendarEvent = @framework.variableManager.setVariableToValue(@calendarEventVariableName, "", "")
        @on 'calendar-event', (value)=>
          @framework.variableManager.setVariableToValue(@calendarEventVariableName, value, "")
      )

      # init first schedule times
      from = new Date()
      to = new Date(from)
      to.setTime(to.getTime() + scheduleInterval)
      @pendingInit = new Promise( (resolve) =>
        recreateTimeouts = () =>
          @cancelTimeouts()
          @scheduleTimeouts(from, to)
        # setup schedule interval
        setInterval( ( () =>
          from = new Date(to)
          to = new Date(to)
          to.setTime(to.getTime() + scheduleInterval)
          recreateTimeouts()
        ), scheduleInterval)

        # fetch calendars
        lastError = null
        refetchCalendar = () =>
          @fetchAllCalendars().then( () =>
            recreateTimeouts()
          ).then( () =>
            setTimeout(refetchCalendar, @updateInterval)
            resolve()
          ).catch((err) =>
            if err?
              env.logger.debug("Error fetching calendars: #{err}")
            setTimeout(refetchCalendar, 10000)
          ).done()
        refetchCalendar()
      )

      @framework.ruleManager.addPredicateProvider(new CalendarEventProvider(@framework))

    # schedules timeouts for all events inside the given interval
    scheduleTimeouts: (from, to) ->
      _.forEach(@calendars, (cal) =>
        allEvents = cal.events or []
        #env.logger.info "allEvents: " + JSON.stringify(allEvents,null,2)

        icalExpander = new IcalExpander({ics: allEvents, maxIterations: 100})
        events = icalExpander.between(from,to)

        #env.logger.debug "Events: " + JSON.stringify(events,null,2)

        mappedEvents = events.events.map((e) => ({ start: e.startDate, end: e.endDate, uid: e.uid, summary: e.summary, description: e.description }))
        mappedOccurrences = events.occurrences.map((o) => ({ start: o.startDate, end: o.endDate, uid: o.item.uid, summary: o.item.summary, description: o.item.description }))
        nextEvents = [].concat(mappedEvents, mappedOccurrences)
        env.logger.debug "nextEvents: " + JSON.stringify(nextEvents,null,2)
        now = new Date()
        # current events

        newOngoingEvents = {}
        #env.logger.info "Running events " + JSON.stringify(_.filter(nextEvents, (info) -> new Date(info.start) <= now and new Date(info.end) > now))
        _.forEach(_.filter(nextEvents, (info) -> new Date(info.start) <= now and new Date(info.end) > now), (info) =>
          uid = info.uid
          newOngoingEvents[uid] = info
        )
        # cancel all not active events (for example deleted ones)
        _.forOwn(@ongoingEvents, (info, uid) =>
          unless newOngoingEvents[uid]?
            @emit 'event-end', info
        )
        # start all not active events (for example newly created ones)
        _.forOwn(newOngoingEvents, (info, uid) =>
          unless @ongoingEvents[uid]?
            @emit 'event-start', info
        )
        @ongoingEvents = newOngoingEvents
        env.logger.debug "Ongoing events: " + JSON.stringify(@ongoingEvents,null,2)

        _.forEach(nextEvents, (info) =>
          currentTime = now.getTime()
          # schedule start if not already started
          _start = new Date(info.start)
          if _start >= from and _start < to
            timeout = Math.max(0, _start.getTime() - currentTime)
            toHandle = setTimeout( ( =>
              uid = info.uid
              unless @ongoingEvents[uid]?
                @ongoingEvents[uid] = info
                @emit 'event-start', info
                #env.logger.info "Event-started ==========> " + info.summary
            ), timeout)
            @scheduledTimeouts.push(toHandle)
            #env.logger.info "Start-event added, timeout = " + timeout + ", info " + JSON.stringify(info,null,2)
          _end = new Date(info.end)
          if _end >= from and _end < to
            timeout = Math.max(0, _end.getTime() - currentTime)
            toHandle = setTimeout( ( =>
              uid = info.uid # info.event.uid
              if @ongoingEvents[uid]?
                delete @ongoingEvents[uid]
                @emit 'event-end', info
                #env.logger.info "Event-stopped ==========> " + info.summary
            ), timeout)
            @scheduledTimeouts.push(toHandle)
            #env.logger.info "End-event added, timeout = " + timeout + ", info " + JSON.stringify(info,null,2)
        )
      )

    cancelTimeouts: ->
      _.forEach(@scheduledTimeouts, (toHandler) ->
        clearTimeout(toHandler)
      )
      @scheduledTimeouts = []


    fetchAllCalendars: () ->
      return Promise.each(@calendars, (cal) =>
        return @fetchCalendar(cal).then( (events) =>
          cal.events = events
        )
      )

    fetchCalendar: (calendar) ->
      return new Promise((resolve,reject) =>
        if calendar.username? and calendar.password?
          opts =
            username: calendar.username
            password: calendar.password
            auth: 'digest'
          needle.get(calendar.ical, opts, (err, resp)=>
            if err?
              env.logger.debug "Error handled in fetchCalendar " + err
              reject(err)
              return
            resolve(resp.body)
          )
        else
          needle.get(calendar.ical, (err, resp)=>
            if err?
              env.logger.debug "Error handled in fetchCalendar " + err
              reject(err)
              return
            resolve(resp.body)
          )
      )

  class CalendarEventProvider extends env.predicates.PredicateProvider

    constructor: (@framework) ->

    parsePredicate: (input, context) ->
      field = null
      fieldValue = null
      checkType = null
      eventType = null

      setField = (m, match) => field = match.trim()
      setCheckType = (m, match) => checkType = match.trim()
      setFieldValue = (m, match) => fieldValue = match.trim()
      setEventType = (m, match) => eventType = match.trim()

      m = M(input, context)
        .match('calendar event with ')
        .match(['title ', 'description '], setField)
        .match(['contains ', 'equals '], setCheckType)
        .matchString(setFieldValue)
        .match([' starts', ' ends', ' takes place'], setEventType)

      if m.hadMatch()
        fullMatch = m.getFullMatch()
        return {
          token: fullMatch
          nextInput: input.substring(fullMatch.length)
          predicateHandler: new CalendarEventHandler(
            field, fieldValue, checkType, eventType
          )
        }
      else
        return null

  class CalendarEventHandler extends env.predicates.PredicateHandler

    constructor: (@field, @fieldValue, @checkType, @eventType) ->
      @state = null

    setup: ->
      calPlugin.on 'event-start', @onEventStart = (info) =>
        if @eventType is 'starts'
          if @_doesMatch info
            calPlugin.emit 'calendar-event', (if @field is 'title' then info.summary else info.description)
            @emit 'change', 'event'
        else if @eventType is 'takes place'
          if @_doesMatch info
            @state = true
            calPlugin.emit 'calendar-event', (if @field is 'title' then info.summary else info.description)
            @emit 'change', true

      calPlugin.on 'event-end', @onEventEnd = (info) =>
        if @eventType is 'ends'
          if @_doesMatch info
            calPlugin.emit 'calendar-event', ""
            @emit 'change', 'event'
        else if @eventType is 'takes place'
          if @_doesMatch info
            @state = false
            calPlugin.emit 'calendar-event', ""
            @emit 'change', false
      super()

    _doesMatch: (info) ->
      eventValue = ""
      if @field is 'title'
        eventValue = info.summary # info.event.summary
      else if @field is 'description'
        eventValue = info.description # .event.description
      unless eventValue?
        return false
      if @checkType is 'equals' and eventValue is @fieldValue
        return true
      if @checkType is 'contains' and eventValue.indexOf(@fieldValue) isnt -1
        return true
      return false

    getType: -> if @eventType is 'takes place' then 'state' else 'event'

    getValue: -> Promise.resolve(@state is true)

    destroy: ->
      calPlugin.removeListener 'event-start', @onEventStart
      calPlugin.removeListener 'event-end', @onEventEnd
      super()


  # ###Finally
  # Create a instance of my plugin
  calPlugin = new CalendarPlugin
  # and return it to the framework.
  return calPlugin
