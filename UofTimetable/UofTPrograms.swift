import Foundation

struct ProgramSection: Identifiable {
    let title: String
    let programs: [String]

    var id: String { title }
}

enum UofTPrograms {
    static let undecided = "Undeclared / Exploring"
    static let other = "Other"

    static func sections(for campus: String) -> [ProgramSection] {
        let campusSections: [ProgramSection]

        switch campus {
        case "UTM":
            campusSections = utm
        case "UTSC":
            campusSections = utsc
        default:
            campusSections = stGeorge
        }

        return campusSections + [ProgramSection(title: "General", programs: [undecided, other])]
    }

    static func filtered(_ sections: [ProgramSection], query: String) -> [ProgramSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }

        return sections.compactMap { section in
            let matches = section.programs.filter {
                $0.localizedCaseInsensitiveContains(trimmed)
                    || section.title.localizedCaseInsensitiveContains(trimmed)
            }
            return matches.isEmpty ? nil : ProgramSection(title: section.title, programs: matches)
        }
    }

    static let stGeorge: [ProgramSection] = [
        ProgramSection(title: "Rotman Commerce", programs: [
            "Rotman Commerce - Accounting Specialist",
            "Rotman Commerce - Finance & Economics Specialist",
            "Rotman Commerce - Management Specialist",
            "Rotman Commerce - International Business Specialist",
            "Rotman Commerce (Undeclared)"
        ]),
        ProgramSection(title: "Faculty of Applied Science & Engineering", programs: [
            "Engineering - Track One (First Year)",
            "Aerospace Engineering",
            "Chemical Engineering",
            "Civil Engineering",
            "Computer Engineering",
            "Electrical Engineering",
            "Engineering Science",
            "Industrial Engineering",
            "Materials Engineering",
            "Mechanical Engineering",
            "Mineral Engineering"
        ]),
        ProgramSection(title: "Arts & Science - Computing & Math", programs: [
            "Computer Science",
            "Data Science",
            "Statistics",
            "Mathematics",
            "Applied Mathematics",
            "Mathematics & Physics",
            "Actuarial Science",
            "Cognitive Science",
            "Linguistics"
        ]),
        ProgramSection(title: "Arts & Science - Life & Physical Sciences", programs: [
            "Life Sciences (Undeclared)",
            "Physical & Mathematical Sciences (Undeclared)",
            "Biology",
            "Molecular Biology",
            "Human Biology",
            "Biochemistry",
            "Immunology",
            "Neuroscience",
            "Pharmacology & Toxicology",
            "Physiology",
            "Microbiology",
            "Ecology & Evolutionary Biology",
            "Environmental Science",
            "Chemistry",
            "Physics",
            "Astronomy & Astrophysics",
            "Earth Sciences",
            "Geology",
            "Psychology",
            "Public Health Sciences",
            "Health & Disease",
            "Anatomy",
            "Nutritional Sciences",
            "Forest Conservation Science"
        ]),
        ProgramSection(title: "Arts & Science - Social Sciences", programs: [
            "Social Sciences (Undeclared)",
            "Economics",
            "Political Science",
            "International Relations",
            "Sociology",
            "Anthropology",
            "Geography",
            "Criminology & Sociolegal Studies",
            "Urban Studies",
            "Equity Studies",
            "Environment & Society",
            "Peace, Conflict & Justice",
            "Women & Gender Studies",
            "Indigenous Studies",
            "Health Studies",
            "Public Policy",
            "Human Geography"
        ]),
        ProgramSection(title: "Arts & Science - Humanities", programs: [
            "Humanities (Undeclared)",
            "English",
            "History",
            "History & Philosophy of Science",
            "Philosophy",
            "Art History",
            "Visual Studies",
            "Cinema Studies",
            "Book & Media Studies",
            "Religion",
            "Classics",
            "Archaeology",
            "Jewish Studies",
            "East Asian Studies",
            "European Studies",
            "Latin American Studies",
            "Middle East & Islamic Studies",
            "French",
            "German",
            "Italian",
            "Spanish",
            "Slavic Languages & Literatures",
            "Near & Middle Eastern Civilizations",
            "Drama, Theatre & Performance Studies",
            "Comparative Literature",
            "Linguistics (Humanities)"
        ]),
        ProgramSection(title: "Professional Faculties", programs: [
            "Architecture (John H. Daniels)",
            "Landscape Architecture",
            "Music (Performance)",
            "Music (Music Education)",
            "Music (Composition)",
            "Music (History & Culture)",
            "Kinesiology",
            "Physical & Health Education",
            "Nursing (Bloomberg)",
            "Pharmacy",
            "Information (iSchool)",
            "Social Work",
            "Education (OISE)",
            "Public Health (Dalla Lana)",
            "Law (JD)",
            "Medicine (MD)",
            "Dentistry (DDS)"
        ]),
        ProgramSection(title: "Graduate - Rotman", programs: [
            "Rotman MBA",
            "Rotman Master of Finance",
            "Rotman Master of Management Analytics",
            "Rotman Master of Financial Risk Management",
            "Rotman Master of Management of Innovation & Entrepreneurship"
        ]),
        ProgramSection(title: "Graduate - Other", programs: [
            "Graduate - Computer Science",
            "Graduate - Engineering (MEng / MASc / PhD)",
            "Graduate - Arts & Science (MA / MSc / PhD)",
            "Graduate - Information (MI)",
            "Graduate - Public Policy (MPP)",
            "Graduate - Global Affairs (MGA)",
            "Graduate - Education (MEd / MT)",
            "Graduate - Social Work (MSW)",
            "Graduate - Nursing (MN)",
            "Graduate - Public Health (MPH)"
        ])
    ]

    static let utm: [ProgramSection] = [
        ProgramSection(title: "UTM - Management & Commerce", programs: [
            "Commerce (UTM)",
            "Management (UTM)",
            "Accounting (UTM)",
            "Finance (UTM)",
            "Marketing (UTM)",
            "Human Resources (UTM)",
            "Economics (UTM)"
        ]),
        ProgramSection(title: "UTM - Sciences", programs: [
            "Life Sciences (UTM)",
            "Biology (UTM)",
            "Biotechnology (UTM)",
            "Biomedical Communications",
            "Forensic Science",
            "Chemistry (UTM)",
            "Biochemistry (UTM)",
            "Physics (UTM)",
            "Mathematics (UTM)",
            "Environmental Science (UTM)",
            "Geography (UTM)",
            "Anthropology (UTM)",
            "Psychology (UTM)",
            "Neuroscience (UTM)",
            "Mental Health Studies",
            "Pharmacology (UTM)",
            "Statistics (UTM)",
            "Earth & Planetary Science"
        ]),
        ProgramSection(title: "UTM - Computing", programs: [
            "Computer Science (UTM)",
            "Data Science (UTM)",
            "Information Systems",
            "Digital Enterprise Management",
            "Applied Statistics",
            "Mathematical Sciences"
        ]),
        ProgramSection(title: "UTM - Social Sciences & Humanities", programs: [
            "Political Science (UTM)",
            "Sociology (UTM)",
            "Criminology & Socio-Legal Studies (UTM)",
            "Education Studies",
            "English (UTM)",
            "History (UTM)",
            "Philosophy (UTM)",
            "Visual Studies (UTM)",
            "Art History (UTM)",
            "Professional Writing & Communication",
            "Language Studies",
            "Linguistics (UTM)",
            "Italian Studies",
            "Communication, Culture, Information & Technology (CCIT)",
            "Drama Studies",
            "Philosophy, Political Science & Economics (UTM)",
            "Urban Studies (UTM)"
        ])
    ]

    static let utsc: [ProgramSection] = [
        ProgramSection(title: "UTSC - Management & Economics", programs: [
            "Management (UTSC)",
            "Management - Accounting (UTSC)",
            "Management - Finance & Economics (UTSC)",
            "Management - Marketing (UTSC)",
            "Management - Human Resources (UTSC)",
            "Economics (UTSC)",
            "Financial Economics",
            "Quantitative Economics",
            "Public Policy (UTSC)",
            "International Development Studies"
        ]),
        ProgramSection(title: "UTSC - Computing & Math", programs: [
            "Computer Science (UTSC)",
            "Data Science (UTSC)",
            "Statistics (UTSC)",
            "Mathematics (UTSC)",
            "Actuarial Science (UTSC)",
            "Applied Mathematics (UTSC)"
        ]),
        ProgramSection(title: "UTSC - Life & Physical Sciences", programs: [
            "Life Sciences (UTSC)",
            "Biology (UTSC)",
            "Molecular Biology & Biotechnology",
            "Neuroscience (UTSC)",
            "Psychology (UTSC)",
            "Mental Health Studies (UTSC)",
            "Health Studies (UTSC)",
            "Human Biology (UTSC)",
            "Chemistry (UTSC)",
            "Physics & Astrophysics",
            "Environmental Science (UTSC)",
            "Environmental Biology",
            "Paleontology",
            "Physical & Environmental Sciences",
            "Pharmacology (UTSC)",
            "Biochemistry (UTSC)"
        ]),
        ProgramSection(title: "UTSC - Social Sciences & Humanities", programs: [
            "Political Science (UTSC)",
            "Sociology (UTSC)",
            "Criminology (UTSC)",
            "Human Geography (UTSC)",
            "Anthropology (UTSC)",
            "Global Asia Studies",
            "African Studies",
            "Women's & Gender Studies (UTSC)",
            "English (UTSC)",
            "History (UTSC)",
            "Philosophy (UTSC)",
            "Journalism (UTSC)",
            "Media Studies (UTSC)",
            "Studio Art (UTSC)",
            "Art History & Visual Culture (UTSC)",
            "Linguistics (UTSC)",
            "Culture, Society & Environment"
        ])
    ]
}
