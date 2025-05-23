## 0.0.1
- Initialized package using jvcli

### 0.0.2
- N/A

### 0.0.3
- Enforce ENV VARS in action registration

### 0.0.4
- Major Refactor of WPPConnectAPI, WPPConnectAction and action app.

### 0.0.5
- Added behaviour to handle quoted messages as context in replies
- Updated action app, added refinements to make UI more usable

### 0.0.6
- Bugfix: incorrect parameter name
- Added ignore forwards setting to ignore forwarded messages by default
- Added a timeout setting for WppConnect API requests as a remedy to the sporadic lockout issue with the WPPConnect service

### 0.0.7
- Patched file_url_to_base64 to selectively apply prefix
- Updated Readme

### 0.0.8
- Patched wppconnect_api to allow messages sent via Agent whatsapp to be received as unprompted interactions

### 0.0.9
- Added outbox scheduler facility, broadcast_message and send_messages endpoints

### 0.0.10
- Set isForwarded to false by default in parse_inbound_message
- remove parent_message_id from handle_voicenote_message, handle_media_message and handle_location_message

### 0.0.11
- Fixed whatsapp group ID bug which prevents agent from responding, even when tagged, when group IDs are used instead of phone number
- Added syncing of Agent name to pushname
- Added syncing of Agent Avatar to profile pic
- Added device details when registered in action app
- Added action app 5 second auto-refresh when awaiting QRcode scan