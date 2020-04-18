pimatic-calendar
================

Pimatic integration of calendar events from ical calendars (e.g. Google Calendar). This plugin provides predicates for ical calendar events.
This plugin is an update of the plugin pimatic-calendar from [sweetpi](https://github.com/pimatic/pimatic-calendar).

Major software changes:
- Ical is replaced by ical-expander for better support of recurring events.
- Request is not maintained anymore and is replaced by needle for http(s) ical requests.
- The calendars settings in the plugin is fixed.


```json
  {
    "plugin": "calendar2",
    "calendars": [
      {
        "name": "Main Calendar",
        "ical": "https://calendar.google.com/calendar/ical/.../basic.ics",
        "username": "Optional, for username authentication",
        "password": "Optional, for password authentication"
      }
    ]
  }
```

The following predicates are supported:
```
when calendar event with [title|description] [contains|equals] "some text" [starts|ends|takes place] then ...
```

The variable 'calendar-event' is created. This variable holds the info of the event title or description when an event is started. If you used the title condition in the rule the calendar-event will contain the title and if description is used, the variable will contain the descrption.
After the event is stopped the variable is set to an empty string.

To get a ical url from your google calendar follow https://support.google.com/calendar/answer/37648 under "See your calendar (view only)". If you use a calendar server with username/password authentication, you can use that optional feature.


----
This plugin is Pimatic version 0.9.x compatible. The minimum node requirement is **node v8!**
