# WPPConnect Action

![GitHub release (latest by date)](https://img.shields.io/github/v/release/TrueSelph/wppconnect_action)
![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/TrueSelph/wppconnect_action/test-action.yaml)
![GitHub issues](https://img.shields.io/github/issues/TrueSelph/wppconnect_action)
![GitHub pull requests](https://img.shields.io/github/issues-pr/TrueSelph/wppconnect_action)
![GitHub](https://img.shields.io/github/license/TrueSelph/wppconnect_action)

JIVAS action wrapper for WhatsApp API communications using the WPPConnect API. This action provides a wrapper for WhatsApp API communications using the [WPPConnect API](https://github.com/wppconnect-team/wppconnect-server). As a core action, it simplifies and streamlines interactions with WhatsApp. The package is a singleton and requires the Jivas library version ^2.1.0.

## Package Information

- **Name:** `jivas/wppconnect_action`
- **Author:** [V75 Inc.](https://v75inc.com/)
- **Architype:** `WPPConnectAction`

## Meta Information

- **Title:** WPPConnect Action
- **Group:** core
- **Type:** action

## Configuration
- **Singleton:** true
## Dependencies
- **Jivas:** `~2.1.0`
- **PulseAction:** `~0.1.0`
- **WPPConnect Server:** `~2.8.5`

---

## How to Use

Below is detailed guidance on how to configure and use the WPPConnect Action.

### Overview

The WPPConnect Action provides an abstraction layer for interacting with WhatsApp via the WPPConnect API. It supports multiple configurations for various use cases, including:

- **Webhook registration** for message handling.
- **Message broadcasting** to multiple recipients.
- **Integration** with WPPConnect for sending text, media, and location messages.

### Dynamic Adaptation

The WPPConnect Action includes advanced mechanisms to optimize message delivery:

- **Automatic Interval Adjustment**: Dynamically modifies send intervals based on success rates to ensure efficient delivery.
- **Variable Batch Sizes**: Alternates batch sizes between defined minimum and maximum values for flexibility.
- **Random Jitter**: Introduces slight randomness to sending intervals to prevent detection of predictable patterns.

These features enhance reliability and minimize disruptions during high-volume messaging operations.

---

### Configuration Structure

To use the WPPConnect Action, you need to set up the following configuration parameters. These specify connection and behavioral details.

| Parameter                     | Type   | Description                                                                                  | Default                     |
|-------------------------------|--------|----------------------------------------------------------------------------------------------|-----------------------------|
| `api_url`                     | string | WPPConnect Server URL (e.g., `"https://your-wppconnect-server.com"`)                         | `""`                        |
| `api_is_wwebjs`               | bool   | Use the [whatsapp-web.js](https://wwebjs.dev/) version of `WPPConnectAPI` when set to `True` | `False`                     |
| `secret_key`                  | string | WPPConnect Server Secret Key for authentication.                                             | `""`                        |
| `token`                       | string | WPPConnect Server API Key for this session.                                                  | `""`                        |
| `session`                     | string | WPPConnect Server Instance ID.                                                               | `""`                        |
| `base_url`                    | string | JIVAS Base URL (your application's base URL).                                                | `""`                        |
| `webhook_url`                 | string | JIVAS webhook endpoint for receiving WPPConnect messages.                                    | `""`                        |
| `request_timeout`             | float  | Length of time (in seconds) this action waits for the API to complete a request.             | `10.0`                      |
| `chunk_length`                | int    | Maximum length of message to send. Longer texts are split into subsequent messages.          | `1024`                      |
| `use_pushname`                | bool   | Use the WhatsApp push name as the user name when set to `True`.                              | `True`                      |
| `ignore_newsletters`          | bool   | Ignore newsletter messages when set to `True`.                                               | `True`                      |
| `ignore_forwards`             | bool   | Ignore forwarded messages when set to `True`.                                                | `True`                      |                                                              | `10`                        |
| `poll_manager_action`         | str    | Action name to manage poll entries.                                                          | `PollManagerInteractAction` |

---

### Notes on Configuration

- **Parameter Settings**: Ensure all parameters are configured based on your WPPConnect Server and JIVAS deployment requirements.
- **Webhook URL**: The `webhook_url` must be a publicly accessible endpoint to enable event-driven communication from WPPConnect.
- **Auto Callback**: This when sending or broadcasting messages in batches, this action will trigger your supplied callback upon completion.
- **Validation**: Validate your API keys, tokens, and webhook URLs before deploying in production.
- **Chunk Length**: Adjust `chunk_length` if you have use cases that involve very long text messages.
- **Message Filtering**: Use `ignore_newsletters` and `ignore_forwards` to filter out less relevant messages and avoid unnecessary processing.

These guidelines help optimize performance and ensure compliance with WhatsApp's messaging policies.

---

## API Endpoints

### Broadcast Message

**Endpoint:** `/action/walker/wppconnect_action/broadcast_message`
**Method:** `POST`

#### Parameters

```json
{
   "agent_id": "<AGENT_ID>",
   "module_root": "actions.jivas.wppconnect_action",
   "args": {
      "message": {
         "message_type": "TEXT|MEDIA|MULTI",
         ...
      },
      "ignore_list": ["session_id_1", ...]
   }
}
```

---

### Send Messages

**Endpoint:** `/action/walker/wppconnect_action/send_messages`
**Method:** `POST`

#### Parameters

```json
{
   "agent_id": "<AGENT_ID>",
   "module_root": "actions.jivas.wppconnect_action",
   "args": {
      "messages": [
         // Array of message objects
      ],
      "callback_url": "https://your-callback.url"
   }
}
```

#### Example Request

```json
{
   "messages": [
      {
         "to": "session_id",
         "message": {
            "message_type": "TEXT",
            "content": "Batch message"
         }
      }
   ],
   "callback_url": "https://example.com/status"
}
```

#### Response

Returns a job ID string for tracking.

#### Callback Response

Your callback will receive a JSON payload with the following structure automatically upon job completion:

```json
{
   "status": "success|partial|error",
   "job_id": "<UUID>",
   "processed_count": 10,
   "failed_count": 2,
   "pending_count": 0
}
```

---

### Message Formats

#### TEXT

```json
{
   "message": {
      "message_type": "TEXT",
      "content": "Hello World"
   }
}
```

#### MEDIA
##### Image
```json
{
   "message": {
      "message_type": "MEDIA",
      "mime": "image/jpeg",
      "content": "Check this!",
      "data": {
         "url": "https://example.com/image.jpg",
         "file_name": "image.jpg"
      }
   }
}
```

##### Polls
```json
{
   "message": {
      "message_type": "MEDIA",
      "mime": "jivas/poll",
      "data": {
         "name": "What's your favorite color?",
         "choices": ["Red", "Green", "Blue"],
         "options": {"selectableCount": 1},
         "duration_minutes": 1440,
         "id": "color_poll_q1"
      }
   }
}
```

#### MULTI

```json
{
   "message": {
      "message_type": "MULTI",
      "content": [
         // Array of TEXT/MEDIA messages
      ]
   }
}
```

---

## 🔰 Contributing

- **🐛 [Report Issues](https://github.com/TrueSelph/wppconnect_action/issues)**: Submit bugs found or log feature requests for the `wppconnect_action` project.
- **💡 [Submit Pull Requests](https://github.com/TrueSelph/wppconnect_action/blob/main/CONTRIBUTING.md)**: Review open PRs, and submit your own PRs.

<details closed>
<summary>Contributing Guidelines</summary>

1. **Fork the Repository**: Start by forking the project repository to your GitHub account.
2. **Clone Locally**: Clone the forked repository to your local machine using a git client.
   ```sh
   git clone https://github.com/TrueSelph/wppconnect_action
   ```
3. **Create a New Branch**: Always work on a new branch, giving it a descriptive name.
   ```sh
   git checkout -b new-feature-x
   ```
4. **Make Your Changes**: Develop and test your changes locally.
5. **Commit Your Changes**: Commit with a clear message describing your updates.
   ```sh
   git commit -m 'Implemented new feature x.'
   ```
6. **Push to GitHub**: Push the changes to your forked repository.
   ```sh
   git push origin new-feature-x
   ```
7. **Submit a Pull Request**: Create a PR against the original project repository. Clearly describe the changes and their motivations.
8. **Review**: Once your PR is reviewed and approved, it will be merged into the main branch. Congratulations on your contribution!
</details>

<details open>
<summary>Contributor Graph</summary>
<br>
<p align="left">
    <a href="https://github.com/TrueSelph/wppconnect_action/graphs/contributors">
        <img src="https://contrib.rocks/image?repo=TrueSelph/wppconnect_action" />
   </a>
</p>
</details>

## 🎗 License

This project is protected under the Apache License 2.0. See [LICENSE](../LICENSE) for more information.
