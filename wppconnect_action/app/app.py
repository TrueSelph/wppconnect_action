"""Streamlit app for WhatsApp Connect action with improved structure and error handling."""

import logging
import re
import time
from typing import Any, Callable, Dict, Optional, Union

import pandas as pd
import streamlit as st
from jvclient.lib.utils import call_api, get_reports_payload
from jvclient.lib.widgets import app_controls, app_header, app_update_action
from requests import HTTPError
from streamlit_router import StreamlitRouter

# Constants
API_TIMEOUT = 30
AUTO_REFRESH_INTERVAL = 5
PAGE_SIZES = [5, 10, 20, 50, 100, 200]
DEFAULT_PAGE_SIZE = 10


# Validation and sanitization helpers
def validate_job_id(job_id: str) -> bool:
    """Validate job ID format (alphanumeric with dashes)."""
    return not job_id or bool(re.match(r"^[a-zA-Z0-9\-_]+$", job_id))


def validate_item_id(item_id: str) -> bool:
    """Validate item ID format (UUID)."""
    return not item_id or bool(
        re.match(
            r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", item_id
        )
    )


def sanitize_html(content: str) -> str:
    """TODO: Safe HTML sanitization."""
    return content


class StateManager:
    """Centralized session state management for WPPConnect."""

    def __init__(self, agent_id: str, action_id: str) -> None:
        """
        Initialize StateManager with agent_id and action_id.

        :param agent_id: ID of the JIVAS agent
        :param action_id: ID of the JIVAS action
        """
        self.prefix = f"wpp_{agent_id}_{action_id}"

    def get(
        self, key: str, default: Union[str, int, float, bool, list, dict, None] = None
    ) -> Union[str, int, float, bool, list, dict, None]:
        """
        Retrieve a value from the session state.

        :param key: The key to retrieve from session state
        :param default: Default value to return if key is not found
        :return: The retrieved value or default if key doesn't exist
        """
        return st.session_state.get(f"{self.prefix}_{key}", default)

    def set(
        self, key: str, value: Union[str, int, float, bool, list, dict, None]
    ) -> None:
        """
        Set a value in the session state.

        :param key: The key to set in session state
        :param value: The value to store
        :return: None
        """
        st.session_state[f"{self.prefix}_{key}"] = value

    def delete(self, key: str) -> None:
        """
        Delete a key from the session state if it exists.

        :param key: The key to delete from session state
        :return: None
        """
        if f"{self.prefix}_{key}" in st.session_state:
            del st.session_state[f"{self.prefix}_{key}"]

    def init_state(
        self, key: str, default: Union[str, int, float, bool, list, dict, None]
    ) -> None:
        """
        Initialize a session state variable with a default value if it doesn't exist.

        :param key: The key to initialize in session state
        :param default: Default value to set if key is not found
        :return: None
        """
        if f"{self.prefix}_{key}" not in st.session_state:
            self.set(key, default)

    def clear_all(self) -> None:
        """
        Clear all session state variables associated with this StateManager instance.

        Removes all keys from session state that start with the instance's prefix.

        :return: None
        """
        keys = list(st.session_state.keys())
        for key in keys:
            if key.startswith(self.prefix):
                del st.session_state[key]


# Set up logging
logger = logging.getLogger(__name__)


def handle_api_call(
    endpoint: str, json_data: Dict[str, Any], success_message: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """
    Standardized API call handler with error handling and logging.

    :param endpoint: API endpoint to call
    :param json_data: JSON payload for the request
    :param success_message: Message to display on success
    :return: Parsed response data or None on failure
    """
    try:
        result = call_api(endpoint=endpoint, json_data=json_data, timeout=API_TIMEOUT)
        if not result:
            raise ConnectionError("No response from API")
        if result.status_code != 200:
            raise ConnectionError(
                f"API returned status {result.status_code}: {result.text}"
            )

        response_data = get_reports_payload(result)
        if not response_data:
            return None

        if success_message:
            st.success(success_message)
        return response_data

    except ConnectionError as ce:
        error_msg = f"Connection error: {str(ce)}"
        logger.error(error_msg)
        st.error(error_msg)
    except HTTPError as he:
        error_msg = f"HTTP error {he.response.status_code}: {he.response.text}"
        logger.error(error_msg)
        st.error(f"API request failed with status {he.response.status_code}")
    except Exception as e:
        error_msg = f"Unexpected error: {str(e)}"
        logger.exception(error_msg)
        st.error(error_msg)

    return None


def validated_input(
    label: str,
    value: str,
    validation_fn: Callable[[str], bool],
    error_msg: str,
    key: str,
) -> Optional[str]:
    """
    Create a validated text input with error messaging.

    :param label: Input label
    :param value: Default value
    :param validation_fn: Validation function
    :param error_msg: Error message to display
    :param key: Unique key for Streamlit widget
    :return: Validated value or None if invalid
    """
    input_val = st.text_input(label, value, key=key)
    if input_val and not validation_fn(input_val):
        st.error(error_msg)
        return None
    return input_val


def _render_session_registration(state: StateManager, agent_id: str) -> None:
    """Render the Session Registration section with reliable auto-refresh."""
    # if not isinstance(state, dict):
    #     state = {}

    def get_wppconnect_status(auto_register: bool = False) -> None:
        """Call and store the latest status in session state."""
        response = handle_api_call(
            endpoint="action/walker/wppconnect_action/register_session",
            json_data={"agent_id": agent_id, "auto_register": auto_register},
            success_message=None,
        )
        if response:
            state.set("session_payload", response)
            state.set("last_refresh", time.time())

    def logout_wppconnect() -> None:
        """Logout session state."""
        if handle_api_call(
            endpoint="action/walker/wppconnect_action/logout_session",
            json_data={"agent_id": agent_id},
            success_message=None,
        ):
            state.set("session_payload", {})
            state.set("last_refresh", time.time())

    def close_wppconnect() -> None:
        """Close session state."""
        if handle_api_call(
            endpoint="action/walker/wppconnect_action/close_session",
            json_data={"agent_id": agent_id},
            success_message=None,
        ):
            state.set("session_payload", {})
            state.set("last_refresh", time.time())

    # Initialize auto-refresh timer
    state.init_state("last_refresh", 0)

    # Fetch initial status if not present
    if not state.get("session_payload"):
        get_wppconnect_status()

    result = state.get("session_payload", {})
    if not isinstance(result, dict):
        result = {}

    with st.expander("WPPConnect Session Registration", expanded=True):
        if result == {}:
            st.error(
                f"{result.get('message', 'Session registration error.')} Check your WPPConnect Configuration and try again.",
                icon="❌",
            )
            if st.button("Refresh", key="manual_refresh_btn"):
                with st.spinner("Refreshing..."):
                    get_wppconnect_status(auto_register=True)
                    st.rerun()
            return

        if result.get("status") == "CONNECTED":
            message = result.get("message", "Session is connected!")
            session = result.get("session")
            device = result.get("device", {}).get("response", {})
            pushname = device.get("pushname", "None provided")
            phone_number = (
                device.get("phoneNumber").split("@")[0]
                if device.get("phoneNumber")
                else ""
            )

            st.success(message, icon="✅")
            st.markdown(
                f"""
                <div style="margin-top: 1em;">
                    <b>Session:</b> <code>{session}</code><br>
                    <b>Push Name:</b> <code>{pushname}</code><br>
                    <b>Phone Number:</b> <code>{phone_number}</code>
                </div>
                """,
                unsafe_allow_html=True,
            )
            st.markdown("<br>", unsafe_allow_html=True)

            st.markdown(
                '<div style="display:flex; justify-content:center;">',
                unsafe_allow_html=True,
            )
            col1, col2, col3 = st.columns([2, 2, 10])
            with col1:
                if st.button(
                    "Logout",
                    key="connected_logout_btn",
                    help="Disconnect this WhatsApp session",
                ):
                    with st.spinner("Logging out..."):
                        logout_wppconnect()
                        st.rerun()
            with col2:
                if st.button("Close", key="connected_close_session_btn"):
                    with st.spinner("Closing session..."):
                        close_wppconnect()
                        st.rerun()
            st.markdown("</div>", unsafe_allow_html=True)

        elif result.get("status") in [
            "INITIALIZING",
            "AWAITING_QR_SCAN",
        ] and not result.get("qrcode"):
            st.warning(
                "Session is initializing. Please wait a moment. Click 'Refresh' to update status. "
                "If too much time elapses, click 'Close Session' to start again",
                icon="ℹ️",
            )
            st.markdown("<br>", unsafe_allow_html=True)

            col1, col2, col3 = st.columns([2, 2, 10])
            with col1:
                if st.button("Refresh", key="init_refresh_session_btn"):
                    with st.spinner("Refreshing session..."):
                        get_wppconnect_status(auto_register=True)
                        st.rerun()
            with col2:
                if st.button("Close", key="init_close_session_btn"):
                    with st.spinner("Closing session..."):
                        close_wppconnect()
                        st.rerun()

        else:
            qrcode = result.get("qrcode", "")
            if not qrcode:
                st.info(
                    "Session is not connected. Start a new session to get the QR Code.",
                    icon="ℹ️",
                )
                st.markdown("<br>", unsafe_allow_html=True)
                col1, col2, col3 = st.columns([2, 2, 10])
                with col1:
                    if st.button("Start", key="not_qr_start_session_btn"):
                        with st.spinner("Starting session..."):
                            get_wppconnect_status(auto_register=True)
                            st.rerun()
            else:
                st.info("Scan the QR code to connect your WhatsApp account.", icon="ℹ️")
                try:
                    if not qrcode.startswith("data:image/png;base64,"):
                        qrcode = f"data:image/png;base64,{qrcode}"
                    st.markdown(
                        f"""
                        <div style="display: flex; justify-content: center;">
                            <img src="{qrcode}" width="500">
                        </div>
                        """,
                        unsafe_allow_html=True,
                    )
                except Exception as ex:
                    st.error(f"There was an error rendering the QR code: {str(ex)}")

                col1, col2, col3 = st.columns([2, 2, 10])
                with col1:
                    if st.button("Refresh", key="refresh_qr_btn"):
                        with st.spinner("Refreshing QR code..."):
                            get_wppconnect_status(auto_register=True)
                            st.rerun()
                with col2:
                    if st.button("Close", key="qr_close_session_btn"):
                        with st.spinner("Closing session..."):
                            close_wppconnect()
                            st.rerun()

        # Auto-update
        session_payload = state.get("session_payload", {})
        if isinstance(session_payload, dict) and session_payload.get("status") not in [
            "CONNECTED",
            "CLOSED",
        ]:
            time.sleep(AUTO_REFRESH_INTERVAL)
            get_wppconnect_status(auto_register=False)
            st.rerun()


def prepare_data(data: list) -> pd.DataFrame:
    """
    Transforms message data into a pandas DataFrame.

    Args:
        data: List of message dictionaries

    Returns:
        DataFrame containing extracted message data
    """
    items = [
        {
            "id": msg["item_id"],
            "status": msg["status"],
            "session_id": msg["session_id"],
            "message_type": msg["message"]["message_type"],
            "content": str(msg["message"]["content"]),
            "added_at": msg["added_at"],
        }
        for msg in data
    ]

    df = pd.DataFrame(items)

    if not df.empty:
        df["added_at"] = pd.to_datetime(df["added_at"])
        df["date"] = df["added_at"].dt.date
        df["time"] = df["added_at"].dt.time

    return df


def render(router: StreamlitRouter, agent_id: str, action_id: str, info: dict) -> None:
    """Main render function for WhatsApp Connect action."""
    state = StateManager(agent_id, action_id)
    model_key, module_root = app_header(agent_id, action_id, info)

    # Initialize state variables individually
    state.init_state("session_payload", {})
    state.init_state("confirm_purge_collection", False)
    state.init_state("current_page", 1)
    state.init_state("per_page", DEFAULT_PAGE_SIZE)
    state.init_state("session_id", [])
    state.init_state("status", [])
    state.init_state("last_refresh", 0)

    with st.expander("WPPConnect Configuration", expanded=False):
        app_controls(agent_id, action_id)
        app_update_action(agent_id, action_id)

    # Render sections
    _render_session_registration(state, agent_id)
