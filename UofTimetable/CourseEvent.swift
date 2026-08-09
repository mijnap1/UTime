//
//  CourseEvent.swift
//  UofTimetable
//

import Foundation
import SwiftData

@Model
final class CourseEvent {
    var uid: String
    var courseCode: String
    var title: String
    var building: String
    var roomNumber: String
    var location: String
    var meetingType: String
    var section: String
    var deliveryMode: String
    var startTime: Date
    var endTime: Date

    init(
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
