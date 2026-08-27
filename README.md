<p align="center">
  <img src="docs/readme/utime-logo.png" alt="UTime app icon" width="104">
</p>

<h1 align="center">UTime</h1>

<p align="center">
  Your U of T timetable, ready before class.
</p>

<p align="center">
  <img alt="Platform iOS" src="https://img.shields.io/badge/platform-iOS-0A66C2?style=flat">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-0A66C2?style=flat">
  <img alt="Live Activities" src="https://img.shields.io/badge/Live%20Activities-ready-0A66C2?style=flat">
  <img alt="iOS 17.6+" src="https://img.shields.io/badge/iOS-17.6%2B-0B2545?style=flat">
</p>

<p align="center">
  UTime is a clean iOS timetable companion for University of Toronto students. Import your `.ics` schedule once, then use Today, Schedule, Alerts, and Profile sections to keep your next class, room, and timing close at hand.
</p>

<p align="center">
  <img src="docs/readme/track-next-class.png" alt="UTime Today screen on iPhone" width="31%">
  <img src="docs/readme/manage-class-schedule.png" alt="UTime schedule import and class list screen" width="31%">
  <img src="docs/readme/customize-alerts.png" alt="UTime live alert settings screen" width="31%">
</p>

## Why UTime

UTime turns a static university calendar export into a live class companion:

- Navigate quickly with dedicated Today, Schedule, Alerts, and Profile sections.
- Track the next class from a focused Today view with a daily snapshot.
- Import a U of T `.ics` timetable and expand recurring weekly classes.
- Manage imported classes from a Schedule view with replace, clear, and swipe-to-delete controls.
- Tune Live Activity timing and red-alert cues before class.
- Show class updates through Lock Screen Live Activities.
- Keep the Dynamic Island focused on the class and room you need next.
- Review your local student profile without creating an account.

## iOS Experience

<p align="center">
  <img src="docs/readme/lock-screen-updates.png" alt="UTime Lock Screen Live Activity" width="45%">
  <img src="docs/readme/dynamic-island.png" alt="UTime Dynamic Island compact class update" width="45%">
</p>

UTime is built around native iPhone surfaces instead of another calendar view to check:

- **Today view** for the next class, room, and day snapshot.
- **Schedule view** for timetable import, replacement, clearing, and class management.
- **Alerts view** for Live Activity start timing and red-alert cues.
- **Profile view** for local student context.
- **Lock Screen updates** for class countdown, start time, and room.
- **Dynamic Island glance** for compact course and room context.
- **Live Activity sync plumbing** for remote update support.

## Calendar Import

The importer supports the calendar details U of T timetables commonly rely on:

- `DTSTART` / `DTEND`
- weekly `RRULE` expansion
- `COUNT`, `UNTIL`, `INTERVAL`, and `BYDAY`
- `EXDATE` skipped classes
- `RDATE` extra or makeup classes
- async, online, and in-person metadata detection

## Tech Stack

- Swift
- SwiftUI
- SwiftData
- ActivityKit / WidgetKit
- Supabase Edge Functions for backend Live Activity support
- iOS 17.6+

## Project Layout

```text
UofTimetable/          Main iOS app
UofTimetableWidget/    Live Activity and widget extension
UofTimetableShared/    Shared ActivityKit attributes
supabase/              Edge functions and migrations
privacy/               Privacy policy page
```

## Run Locally

1. Open `UofTimetable.xcodeproj` in Xcode.
2. Select the `UofTimetable` scheme.
3. Choose an iPhone simulator or connected iPhone.
4. Build and run.

For Live Activities, use a device or simulator/runtime that supports ActivityKit.

## Import A Timetable

1. Export your timetable as an `.ics` calendar file.
2. Open UTime and choose **Schedule**.
3. Import or replace the `.ics` file.
4. Open **Alerts** to set how early Live Activities and red cues should appear.
5. Let UTime surface the next class before it starts.

## Privacy

Read the UTime privacy policy at [jamieryu.com/UTime/privacy](https://jamieryu.com/UTime/privacy/index.html).

## Notes

UTime is designed for University of Toronto timetable exports. Other `.ics` calendars may import successfully, but the course, section, room, and delivery-mode parsing is tuned for U of T class data.

## Copyright

Copyright (c) 2026 Jamie Ryu. All rights reserved.
