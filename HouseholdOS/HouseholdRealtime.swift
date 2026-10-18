import Foundation

extension BackendClient {
    // Realtime is an invalidation signal; snapshots and versioned RPC writes
    // remain authoritative. Reconnect always pulls a snapshot for missed events.
    func watchHousehold(_ id:UUID,onChange:@escaping @MainActor () async -> Void) async throws {
        guard let base = configuration.url,
              var components = URLComponents(url:base,resolvingAgainstBaseURL:false) else { throw BackendError.configuration }
        components.scheme = "wss"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name:"apikey",value:configuration.publicKey),URLQueryItem(name:"vsn",value:"1.0.0")]
        guard let url = components.url else { throw BackendError.configuration }
        let socket = URLSession.shared.webSocketTask(with:url)
        socket.resume()
        let topic = "realtime:household-\(id.uuidString.lowercased())"
        func send(topic:String,event:String,payload:[String:Any],ref:String) async throws {
            let data = try JSONSerialization.data(withJSONObject:["topic":topic,"event":event,"payload":payload,"ref":ref])
            try await socket.send(.data(data))
        }
        try await send(topic:topic,event:"phx_join",payload:[
            "access_token":try await accessToken(),
            "config":["broadcast":["ack":false,"self":false],"presence":["enabled":false],"postgres_changes":[
                ["event":"*","schema":"public","table":"household_records","filter":"household_id=eq.\(id.uuidString.lowercased())"],
                ["event":"*","schema":"public","table":"household_members","filter":"household_id=eq.\(id.uuidString.lowercased())"]
            ]]
        ],ref:"join")
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for:.seconds(20))
                try await send(topic:"phoenix",event:"heartbeat",payload:[:],ref:UUID().uuidString)
                try await send(topic:topic,event:"access_token",payload:["access_token":try await accessToken()],ref:UUID().uuidString)
            }
        }
        defer { heartbeat.cancel(); socket.cancel(with:.goingAway,reason:nil) }
        try await withTaskCancellationHandler {
            await onChange()
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data:Data
                switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
                guard let event = try JSONSerialization.jsonObject(with:data) as? [String:Any], let name = event["event"] as? String else { continue }
                if name == "postgres_changes" { await onChange() }
                if name == "phx_error" || name == "phx_close" { throw BackendError.server("Live updates disconnected.") }
                if name == "phx_reply", let payload = event["payload"] as? [String:Any], payload["status"] as? String == "error" { throw BackendError.server("Live updates are unavailable.") }
            }
        } onCancel: { socket.cancel(with:.goingAway,reason:nil) }
    }
}
