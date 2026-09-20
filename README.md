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
  Enter your weekly timetable once, then use <strong>Today</strong>, <strong>Schedule</strong>, <strong>Alerts</strong>, and <strong>Profile</strong> to keep your next class, room, delivery mode, and Live Activity timing close at hand.
</p>

<p align="center">
  <img src="docs/readme/track-next-class.png" alt="UTime Today screen on iPhone" width="31%">
  <img src="docs/readme/manage-class-schedule.png" alt="UTime schedule import and class list screen" width="31%">
  <img src="docs/readme/customize-alerts.png" alt="UTime live alert settings screen" width="31%">
</p>

## Overview

UTime turns a weekly U of T timetable into a practical class companion for iPhone. Instead of checking a full calendar every time you need a room, UTime focuses on the question students usually care about most:

**What is my next class, when does it start, and where do I need to go?**

The app is organized around a bottom navigation bar with four focused sections:

- **Today** shows the next class, the room, and a compact overview of the day.
- **Schedule** handles manual course entry, clearing, and upcoming class management.
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

The **Schedule** section lets you add courses manually, with term dates and weekly lecture, tutorial, lab, or seminar meetings. Review generated class dates and swipe to exclude holidays before saving. New courses are appended to the existing schedule. Use **Upload timetable** to scan an ACORN PNG from Files or Photos. Recognition runs on-device, and all extracted courses can be edited before saving.

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

## Timetable Entry

Manual entry uses Toronto time and expands weekly meetings across the selected term, preserving local class times across daylight-saving changes. Set in-person locations or mark a meeting as online. Review class dates before saving; holidays and reading week are not excluded automatically. Saved occurrences can be deleted individually from Schedule.

ICS import has been removed. Existing saved schedules remain available. PNG import reads the full Course / Day / Time / Location table beneath the grid. Grid-only screenshots are not supported. The review includes the original image and requires confirmation of meetings and exact term dates. AM/PM is inferred (1–7 default to afternoon), so check times before saving. The image does not provide holidays or the winter schedule of a year-long course.

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

## Add a Timetable in the App

1. Open **Schedule** and tap **Add a course**.
2. Enter the course, term dates, and weekly meetings. Alternatively, choose **Upload timetable**, select an image, and check the scanned courses.
3. Tap **Review course**, remove any excluded dates, then **Save**.
4. Repeat for the next course; term dates are remembered.
5. Open **Alerts** to set Live Activity timing.

## Checks

```sh
swiftc UofTimetable/CourseReminderSnapshot.swift UofTimetable/ManualCourse.swift tests/ManualCourseChecks.swift -o /tmp/manual-course-checks
/tmp/manual-course-checks
swiftc UofTimetable/CourseReminderSnapshot.swift UofTimetable/ManualCourse.swift UofTimetable/TimetableImageParser.swift tests/TimetableImageChecks.swift -o /tmp/timetable-image-checks
/tmp/timetable-image-checks
```

The image checks also accept the original sample PNG path as an argument to validate actual Vision output against the expected four courses and nine weekly meetings.

## Notes

The App Store review action opens UTime’s App Store review page directly, which makes the Profile review row reliable when someone chooses to use it.

## Copyright

Copyright (c) 2026 Jamie Ryu. All rights reserved.
