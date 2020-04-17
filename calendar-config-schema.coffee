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
    updateInterval:
      description: "Interval in which the ical file is fetched"
      type: "integer"
      default: 3600000
}
