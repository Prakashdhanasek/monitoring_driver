# Technical Proposal: Live Camera & Screen Sharing for Driver Monitoring System

This document outlines the architectural possibilities, implementation strategies, and potential drawbacks of streaming the mobile application's screen/camera feed to the Web Admin Dashboard. 

Given the application's unique operational constraints—specifically, running real-time YOLO/Face Mesh AI models and operating on vehicle cellular networks (IoT SIMs)—this proposal highlights the most stable and performant approaches.

---

## 1. Architectural Options & Feasibility

We have evaluated three primary approaches for transmitting the camera feed and screen state to the Web Admin Dashboard:

| Criteria | Option A: WebSocket Frame Streaming (Recommended) | Option B: WebRTC Real-Time Stream | Option C: State-Based Mirroring |
| :--- | :--- | :--- | :--- |
| **Description** | Compress camera frames into low-res JPEG files and transmit them sequentially over WebSockets. | Establish a peer-to-peer real-time video connection using standard VoIP protocol. | Send small JSON data updates describing the UI state and active alerts. |
| **Visual Fidelity** | Moderate-High (Plays like a 10 FPS video stream) | Very High (30 FPS smooth video) | Low-Moderate (Renders a virtual representation) |
| **Network Overhead** | Low (Only active when the Admin is actively watching) | High (Continuous high-bandwidth transmission) | Extremely Low (< 1 KB/s) |
| **CPU / Battery Impact**| Low-Moderate (Managed via background thread worker) | Critical (High risk of device lag and thermal throttle) | Negligible |
| **Implementation Complexity** | Simple (Built on standard WebSockets) | Complex (Requires STUN/TURN servers & signal handling) | Simple |

---

## 2. Option A: WebSocket Frame Streaming (On-Demand)

### Concept
Instead of continuously streaming video, streaming is strictly **On-Demand**. The mobile app remains idle until the Admin clicks **"View Live Stream"** on the dashboard. Upon request, the app captures camera frames, compresses them to low-resolution JPEG images, and forwards them over an active WebSocket connection.

### Implementation Guide
1. **Signal Handlers:** Establish a WebSocket listener in the Flutter app.
   - On receiving `{"command": "START_STREAM"}`, set `_isStreaming = true`.
   - On receiving `{"command": "STOP_STREAM"}`, set `_isStreaming = false`.
2. **Background Processing (Isolate):** To prevent blocking the main thread (which runs YOLO AI models), offload image compression to a background thread:
   ```dart
   import 'package:flutter/foundation.dart';

   // Inside the camera stream callback:
   if (_isStreaming) {
     // Offload heavy JPEG encoding to a background isolate
     compute(compressFrameToJpeg, rawFrameBytes).then((compressedBytes) {
       webSocketChannel.sink.add(compressedBytes);
     });
   }
   ```
3. **Web Dashboard Receiver:** In the browser, listen for incoming binary chunks and render them in a standard HTML `<img>` tag:
   ```javascript
   socket.onmessage = (event) => {
     const blob = new Blob([event.data], { type: 'image/jpeg' });
     document.getElementById('live-stream-view').src = URL.createObjectURL(blob);
   };
   ```

### Drawbacks & Resource Constraints
* **Frame Rate Limit:** Capped at 10–15 FPS depending on network speeds.
* **CPU Overhead:** Compressing frames, even in a background isolate, consumes extra CPU cycles. If the mobile device is low-spec, it may decrease the local YOLO detection speed.

---

## 3. Option B: WebRTC Video Streaming

### Concept
WebRTC is the standard protocol for real-time video conferencing (like Zoom or Teams). The mobile app acts as the publisher, capturing the camera track and publishing it to a WebRTC media channel.

### Implementation Guide
1. **SDK Integration:** Add `flutter_webrtc` to the mobile project.
2. **Infrastructure Setup:** Deploy a **STUN/TURN server** (e.g., Coturn). This is mandatory because vehicles using IoT SIM cards sit behind carrier-grade NATs and firewalls, which prevent direct peer-to-peer connections.
3. **Signaling:** Create a WebSocket signaling server to exchange Session Description Protocol (SDP) packets and ICE candidates between the browser and mobile device.
4. **Media Capture:** Bind the camera controller feed to a `RTCVideoTrack` and initiate transmission.

### Drawbacks & Resource Constraints
* **Critical CPU & Thermal Issues:** Real-time video encoding (H.264/VP8) is extremely processor-intensive. When combined with local YOLO / TFLite face models, the mobile device will likely overheat, trigger thermal throttling, and cause the app to crash.
* **Massive Data Consumption:** WebRTC operates at a high bitrate. A single hour of live streaming can consume **over 1.5 GB of data**.
* **High Infrastructure Cost:** Setting up and running TURN servers in the cloud to relay video traffic incurs high recurring server costs.

---

## 4. Option C: State-Based Mirroring (Hybrid Option)

### Concept
The mobile app does not send any video frames. It only sends JSON packets representing the state (e.g., `"drowsy": true`, `"speed": 62`, `"active_banner": "smoke"`). The Web Admin Dashboard uses this data to reconstruct a virtual dashboard/phone interface.

### Implementation Guide
1. **State Serialization:** Write a utility method in the app to serialize the active UI state to JSON:
   ```json
   {
     "vehicleId": "V-101",
     "activeAlert": "Cigarette Detected",
     "speed": 65,
     "connection": "Good"
   }
   ```
2. **WebSocket Dispatch:** Send this lightweight JSON payload every time a state changes.
3. **Web Dashboard Mirroring:** Recreate the app's screen layout using standard web components (HTML/CSS). When the payload is received, update the UI states dynamically.

### Drawbacks & Resource Constraints
* **No Live Video:** The manager will see the alert status and telemetry, but *cannot* visually inspect the driver's face in real-time. (However, this can be combined with **short video clip uploads** when alerts are triggered).

---

## 5. Potential Impact on Mobile App Performance (Critical Considerations)

### A. Thread Blockage (Jank)
Flutter runs on a single main thread (Isolate) by default. If the camera stream is converted to JPEG on this main thread:
* **The Drawback:** Frame rate of the YOLO detector will drop significantly (e.g., from 15 FPS to 5 FPS).
* **The Fix:** Must use a background `Isolate` (Option A) to handle compression asynchronously.

### B. Network Bandwidth (IoT SIM Restrictions)
IoT SIM cards designed for vehicles usually have restricted data limits (e.g., 2 GB per month). 
* **The Drawback:** Continuous streaming will exhaust the entire monthly limit in a few hours.
* **The Fix:** Implement the **On-Demand** toggle. The stream must auto-terminate after 2 minutes of viewing, or when the Admin navigates away from the vehicle's detail page.

### C. Battery & Thermal Throttling
Vehicle dashboards are often exposed to direct sunlight, which naturally heats the device.
* **The Drawback:** Running the camera, YOLO detection, and video encoding simultaneously draws high power. The device will run hot, causing Android/iOS to throttle CPU speed to prevent battery damage. This throttling slows down the AI models.

---

## 6. Recommendation

We recommend implementing **Option A (On-Demand WebSocket Frame Streaming)** paired with **Option C (State Mirroring)**. 

1. Show the driver's state (speed, active alerts) continuously on the web dashboard using low-data JSON.
2. Provide a **"View Live Cabin Cam"** button. 
3. When clicked, activate the camera frame transmitter on the mobile app using a background isolate for a maximum of 2 minutes, then automatically shut it down to protect the vehicle's IoT SIM data and keep the device cool.
