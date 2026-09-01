<p align="center">
  <img src="docs/readme/utime-logo.png" alt="UTime app icon" width="104">
</p>

<h1 align="center">UTime</h1>

<p align="center">
  A clean iOS timetable companion for University of Toronto students.
</p>

<p align="center">
  <img alt="Platform iOS" src="https://img.shields.io/badge/platform-iOS-0A66C2?style=flat">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-0A66C2?style=flat">
  <img alt="Live Activities" src="https://img.shields.io/badge/Live%20Activities-ready-0A66C2?style=flat">
  <img alt="iOS 17.6+" src="https://img.shields.io/badge/iOS-17.6%2B-0B2545?style=flat">
</p>

<p align="center">
  Import your <code>.ics</code> timetable once, then use <strong>Today</strong>, <strong>Schedule</strong>, <strong>Alerts</strong>, and <strong>Profile</strong> to keep your next class, room, delivery mode, and Live Activity timing close at hand.
</p>

<p align="center">
  <img src="docs/readme/track-next-class.png" alt="UTime Today screen on iPhone" width="31%">
  <img src="docs/readme/manage-class-schedule.png" alt="UTime schedule import and class list screen" width="31%">
  <img src="docs/readme/customize-alerts.png" alt="UTime live alert settings screen" width="31%">
</p>

## Overview

UTime turns a static U of T calendar export into a practical class companion for iPhone. Instead of checking a full calendar every time you need a room, UTime focuses on the question students usually care about most:

**What is my next class, when does it start, and where do I need to go?**

The app is organized around a bottom navigation bar with four focused sections:

- **Today** shows the next class, the room, and a compact overview of the day.
- **Schedule** handles `.ics` import, replacement, clearing, and upcoming class management.
- **Alerts** controls when Live Activities appear and when urgent cues should start.
- **Profile** keeps local student context and app actions in one quiet place.

## v1.3 Highlights

Version `1.3` focuses on making the app feel more complete and easier to move through:

- Added a persistent bottom navigation bar for clearer app sections.
- Refined the **Today** page with a focused next-class card and a cleaner overview panel.
- Expanded the **Schedule** page with import steps, upcoming classes, and clearer course metadata.
- Added support for showing `Async` and `Sync` class types when a room is not available.
- Improved **Alerts** with Live Activity timing, island controls, and red-alert cue settings.
- Added a subtle **Rate UTime** action in Profile that opens the App Store review page.
- Updated README screenshots to match the current app screens.

## Screenshots

<p align="center">
  <img src="docs/readme/lock-screen-updates.png" alt="UTime Lock Screen Live Activity" width="45%">
  <img src="docs/readme/dynamic-island.png" alt="UTime Dynamic Island compact class update" width="45%">
</p>

UTime is designed around native iPhone surfaces instead of becoming another heavy calendar screen. The app keeps the main interface calm, then uses Lock Screen and Dynamic Island surfaces when timing matters.

## Core Features

### Today

The **Today** section is the main landing view. It highlights the next class with the course code, section details, start time, date, and room when one is available. Below that, the overview panel keeps the day readable with counts for classes today, upcoming classes, alert timing, and Dynamic Island status.

### Schedule

The **Schedule** section is where timetable data is imported and managed. UTime accepts an `.ics` file exported from a timetable, expands recurring classes, and displays future classes in a clean list. Imported schedules can be replaced or cleared without creating an account.

### Alerts

The **Alerts** section controls how early UTime starts Live Activity updates before class. It also lets users choose a red-alert cue, so the app can become more noticeable as the start time gets closer.

### Profile

The **Profile** section stores local student details such as campus, program, year, and imported class count. It also includes a small **Rate UTime** row for users who want to leave an App Store review, without turning the page into a promotion screen.

## Live Activities

UTime uses native iOS Live Activities to keep the next class visible when it matters most:

- **Lock Screen** updates show the course, room or delivery mode, countdown, and start time.
- **Dynamic Island** keeps the compact view focused on the course and room.
- **Alert timing** can be adjusted so updates appear before class instead of at the last second.
- **Red-alert cues** help make the final minutes before class easier to notice.

The goal is not to mirror the whole schedule on the Lock Screen. UTime only surfaces the immediate next class, which keeps the experience focused and glanceable.

## Calendar Import

The importer is tuned for U of T timetable exports and supports the calendar details those files commonly rely on:

- `DTSTART` / `DTEND`
- weekly `RRULE` expansion
- `COUNT`, `UNTIL`, `INTERVAL`, and `BYDAY`
- `EXDATE` skipped classes
- `RDATE` extra or makeup classes
- in-person, async, and sync/online metadata detection

When a class has a physical room, UTime shows the room. When a class has no room but includes online delivery metadata, UTime can show `Async` or `Sync` instead, keeping the schedule readable without blank trailing details.

## Privacy and Data

UTime is built around local timetable use:

- Student profile details stay on device.
- Imported class data is used to power the app’s schedule and Live Activity views.
- No account is required to import or view a timetable.
- Live Activity support uses only the data needed to show class updates.

Read the full privacy policy at [jamieryu.com/UTime/privacy](https://jamieryu.com/UTime/privacy/index.html).

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

## Import a Timetable in the App

1. Export your timetable as an `.ics` calendar file.
2. Open UTime and choose **Schedule**.
3. Import or replace the `.ics` file.
4. Open **Alerts** to set how early Live Activities and red cues should appear.
5. Let UTime surface the next class before it starts.

## Notes

UTime is designed for University of Toronto timetable exports. Other `.ics` calendars may import successfully, but the course, section, room, recurrence, and delivery-mode parsing is tuned for U of T class data.

The App Store review action opens UTime’s App Store review page directly, which makes the Profile review row reliable when someone chooses to use it.

## Copyright

Copyright (c) 2026 Jamie Ryu. All rights reserved.
