import Foundation

enum CalendarSnapshot {
    static func data(records:[SharedRecord],now:Date = Date()) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.calendar = Calendar(identifier:.gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT:0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        func escape(_ value:String) -> String {
            value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:",",with:"\\,").replacingOccurrences(of:";",with:"\\;")
        }
        // RFC 5545 folding: keep UTF-8 scalars intact and lines <=75 octets.
        func fold(_ value:String) -> String {
            var lines:[String] = []; var line = ""
            for scalar in value.unicodeScalars {
                let text = String(scalar)
                if line.utf8.count+text.utf8.count>74 { lines.append(line); line = " " }
                line += text
            }
            lines.append(line)
            return lines.joined(separator:"\r\n")
        }
        var lines = ["BEGIN:VCALENDAR","VERSION:2.0","PRODID:-//Household OS//Household Agenda//EN","CALSCALE:GREGORIAN"]
        for record in records where !record.deleted && !record.isFinished {
            guard let due = record.payload.dueAt else { continue }
            lines += ["BEGIN:VEVENT","UID:\(record.id.uuidString.lowercased())@householdos.local","DTSTAMP:\(formatter.string(from:now))","DTSTART:\(formatter.string(from:due))","DTEND:\(formatter.string(from:due.addingTimeInterval(900)))","SEQUENCE:\(record.version)","SUMMARY:\(escape(record.payload.title))","DESCRIPTION:\(escape(record.payload.notes))","END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return Data((lines.map(fold).joined(separator:"\r\n")+"\r\n").utf8)
    }
}
