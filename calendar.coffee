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

      scheduleInterval = 120*60*1000

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
          env.logger.info "Start fetchAllCalendars"
          @fetchAllCalendars().then( () =>
            env.logger.info "All Calendars fetched"
            recreateTimeouts()
          ).then( () =>
            resolve()
            setTimeout(refetchCalendar, @config.updateInterval)
          ).catch( (err) =>
            unless err.message is lastError?.message
              env.logger.error("Error fetching calendars: #{err.message}")
              env.logger.debug(err)
              lastError = err
            setTimeout(refetchCalendar, 10000)
          ).done()
        env.logger.info "IN pendingInit ++++++++++++++++++"
        refetchCalendar()
      )

      @framework.ruleManager.addPredicateProvider(new CalendarEventProvider(@framework))

    # schedules timeouts for all events inside the given interval
    scheduleTimeouts: (from, to) ->
      _.forEach(@calendars, (cal) =>
        allEvents = cal.events or []

        icalExpander = new IcalExpander({ics: allEvents, maxIterations: 100})
        events = icalExpander.between(from,to) 

        mappedEvents = events.events.map((e) => ({ start: e.startDate, end: e.endDate, uid: e.uid, summary: e.summary, description: e.description }))
        mappedOccurrences = events.occurrences.map((o) => ({ start: o.startDate, end: o.endDate, uid: o.uid, summary: o.summary, description: o.description }))
        nextEvents = [].concat(mappedEvents, mappedOccurrences)
        env.logger.info "nextEvents: " + JSON.stringify(nextEvents,null,2)
        now = new Date()
        # current events

        newOngoingEvents = {}
        _.forEach(_.filter(nextEvents, (info) -> info.start <= now and info.end > now), (info) =>
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

        _.forEach(nextEvents, (info) =>
          currentTime = now.getTime()
          # scedule start if not already started
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
        needle.get(calendar.ical, (err,resp) =>
          if err?
            env.logger.debug "Error handled in fetchCalendar " + err
            reject(err)
          resolve(resp.body)
        )
      )

    ###
    getNextEvents: (events, from, to) ->
      result = []
      _.forEach(events, (event) =>
        if event.rrule?
          duration = event.end.getTime() - event.start.getTime()
          # include events, that are ongoing
          fromRrule = new Date(from)
          fromRrule.setTime(fromRrule.getTime() - duration)
          # get recurring events
          dates = event.rrule.between(fromRrule, to, true)
          _.forEach(dates, (date) =>
            # calculate end
            end = new Date(date)
            end.setTime(date.getTime()+duration)
            # add to result list
            result.push({
              start: date
              end: end
              event: event
            })
          )
        # event starts between from and to or event is already started and ongoing
        else if (event.start >= from and event.start <= to) or
                (event.end >= from and event.start <= from)
          # no recurring event, only add ones
          result.push({
            start: event.start
            end: event.end
            event: event
          })
      )
      return _.sortBy result, (r) => r.start
    ###

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
            @emit 'change', 'event'
        else if @eventType is 'takes place'
          if @_doesMatch info
            @state = true
            @emit 'change', true

      calPlugin.on 'event-end', @onEventEnd = (info) =>
        if @eventType is 'ends'
          if @_doesMatch info
            @emit 'change', 'event'
        else if @eventType is 'takes place'
          if @_doesMatch info
            @state = false
            @emit 'change', false
      super()

    _doesMatch: (info) ->
      eventValue = ""
      if @field is 'title'
        eventValue = info.summary # info.event.summary
      else if @field is 'description'
        eventValue = info.description # .event.description
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