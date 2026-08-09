//
//  CourseReminderSnapshot.swift
//  UofTimetable
//

import Foundation

struct CourseEventDraft: Sendable, Hashable {
    let uid: String
    let courseCode: String
    let title: String
    let building: String
    let roomNumber: String
    let location: String
    let meetingType: String
    let section: String
    let deliveryMode: String
    let startTime: Date
    let endTime: Date

    nonisolated init(
        uid: String,
        courseCode: String,
        title: String,
        building: String,
        roomNumber: String,
        location: String,
        meetingType: String,
        section: String,
        deliveryMode: String,
        startTime: Date,
        endTime: Date
    ) {
        self.uid = uid
        self.courseCode = courseCode
        self.title = title
        self.building = building
        self.roomNumber = roomNumber
        self.location = location
        self.meetingType = meetingType
        self.section = section
        self.deliveryMode = deliveryMode
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct CourseReminderSnapshot: Sendable, Hashable {
    let uid: String
    let courseCode: String
    let building: String
    let roomNumber: String
    let meetingType: String
    let section: String
    let deliveryMode: String
    let startTime: Date
    let endTime: Date

    var locationText: String {
        [building, roomNumber]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var hasPhysicalLocation: Bool {
        !locationText.isEmpty && deliveryMode != "Asynchronous" && deliveryMode != "Online"
    }

    nonisolated init(
        uid: String,
        courseCode: String,
        building: String,
        roomNumber: String,
        meetingType: String,
        section: String,
        deliveryMode: String,
        startTime: Date,
        endTime: Date
    ) {
        self.uid = uid
        self.courseCode = courseCode
        self.building = building
        self.roomNumber = roomNumber
        self.meetingType = meetingType
        self.section = section
        self.deliveryMode = deliveryMode
        self.startTime = startTime
        self.endTime = endTime
    }

    nonisolated init(draft: CourseEventDraft) {
        self.init(
            uid: draft.uid,
            courseCode: draft.courseCode,
            building: draft.building,
            roomNumber: draft.roomNumber,
            meetingType: draft.meetingType,
            section: draft.section,
            deliveryMode: draft.deliveryMode,
            startTime: draft.startTime,
            endTime: draft.endTime
        )
    }
}
