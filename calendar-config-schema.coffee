module.exports = {
  title: "calendar config options"
  type: "object"
  properties:
    calendars:
      description: "Calendars to subscribe to"
      type: "array"
      format: "table"
      items:
        type: "object"
        properties:
          name:
            description: "The name of the calendar"
            type: "string"
          ical:
            description: "Url to ical file"
            type: "string"
          username:
            description: "Username for getting ical file"
            type: "string"
            required: false
          password:
            description: "Password for getting ical file"
            type: "string"
            required: false
    updateInterval:
      description: "Interval in which the ical file is fetched"
      type: "integer"
      default: 3600000
    debug:
      description: "Debug mode. Writes debug messages to the pimatic log, if set to true."
      type: "boolean"
      default: false
}
