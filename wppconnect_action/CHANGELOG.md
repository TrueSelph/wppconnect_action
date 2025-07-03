## 0.0.1
- Initialized package using jvcli

### 0.0.2
- N/A

### 0.0.3
- Enforce ENV VARS in action registration

### 0.0.4
- Major Refactor of WPPConnectAPI, WPPConnectAction and action app.

### 0.0.5
- Added behavior to handle quoted messages as context in replies
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

### 0.0.12
- Updated the `file_url_to_base64` function to use filetype to determine MIME type
- **Poll Dispatch Capability:**
  - The `send_message` ability can now dispatch polls via the WPPConnect API.
  - This is triggered when an `InteractionMessage` with `message.mime == "jivas/poll"` (or `message_item.mime` for `MULTI` messages) is passed.
  - The underlying WPPConnect API's `send_poll_message` method is called.
- **Integration with PollManagerAction:**
  - Added a new `has poll_manager_action: str = "PollManagerInteractAction";` configuration variable (DAF configurable) to specify the label of the action responsible for managing poll definitions and results (e.g., `PollManagerInteractAction`).
  - After successfully dispatching a poll via WPPConnect, if the `poll_manager_action` is found and enabled, its `register_dispatched_poll_instance` ability is called.
  - This registers the dispatched WhatsApp poll ID and its definition with the poll management system, allowing for centralized tracking of votes and poll lifecycle.
  - The `internal_poll_group_id` returned by `register_dispatched_poll_instance` is now included in the `result` dictionary of the `send_message` ability when a poll is sent.

### Changed

- **`send_message` Ability Logic:**
  - Modified to check `message.mime` (or `message_item.mime`) for the special type "jivas/poll" within the `MessageType.MEDIA` and `MessageType.MULTI` handling blocks.
  - If "jivas/poll" is detected, it extracts poll data from `message.data` (or `message_item.data`) and calls `self.api().send_poll_message(...)`.
  - After a successful poll dispatch, it retrieves the `PollManagerInteractAction` (or the action specified by `self.poll_manager_action`) and calls its `register_dispatched_poll_instance` method.

### Documentation - Sending Polls via `WPPConnectAction.send_message`

To dispatch a poll using the `WPPConnectAction.send_message` ability, construct an `InteractionMessage` (typically a `MediaInteractionMessage` or a component of a `MultiInteractionMessage`) with the following structure:

- **`message.mime`**: Must be set to `"jivas/poll"`.
- **`message.data`**: A dictionary containing the poll details. Expected keys within `message.data`:
    - **`name`**: (String) The question or name of the poll.
    - **`choices`**: (List[String]) A list of strings representing the poll options.
    - **`options`**: (Optional[Dict]) A dictionary for WPPConnect-specific poll options.
        - Example: `{"selectableCount": 1}`.
        - This is passed directly to `self.api().send_poll_message`.
    - **`duration_minutes`**: (Optional[Integer]) If provided in `message.data`, this will be included in the `poll_definition.options` passed to `PollManagerInteractAction.register_dispatched_poll_instance` for lifecycle management. It is *not* directly used by `WPPConnectAPI.send_poll_message`.
    - **`id` / `preferred_internal_id`**: (Optional[String]) If present in `message.data`, this value will be passed as `preferred_internal_id` to `PollManagerInteractAction.register_dispatched_poll_instance`. The action will prioritize `message.data.id` if both are present.

**Example `InteractionMessage` Payload for Sending a Poll:**

```python
# Assuming 'poll_im' is a MediaInteractionMessage instance
poll_im.mime = "jivas/poll"
poll_im.content = "Optional: Caption for the poll message, if supported by WPPConnect for polls."
poll_im.data = {
    "name": "What's your favorite color?",
    "choices": ["Red", "Green", "Blue"],
    "options": {"selectableCount": 1}, # WPPConnect options
    "duration_minutes": 1440, # 24 hours, for PollManagerInteractAction
    "id": "color_poll_q1" # Optional: preferred internal ID for PollManagerInteractAction
}

# Then call:
# wpp_action_node.send_message(session_id="user_whatsapp_id", message=poll_im)
```

## 0.0.13

**Breaking Changes:**
- Removed deprecated file interface implementation

**Improvements:**
- Upgraded to new file interface implementation with enhanced performance and reliability

## 0.0.14

- Updated documentation to include the details on how to send polls.

## 0.0.15
- Update action to store outbox in collection.

## 0.1.0
- Updated to support Jivas 2.1.0