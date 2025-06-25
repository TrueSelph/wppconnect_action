"""This module contains the Streamlit app for the WhatsApp Connect action."""

import json
import time

import streamlit as st
import yaml
from jvcli.client.lib.utils import call_action_walker_exec
from jvcli.client.lib.widgets import app_controls, app_header, app_update_action
from streamlit_router import StreamlitRouter


def render(router: StreamlitRouter, agent_id: str, action_id: str, info: dict) -> None:
    """
    Render the Streamlit app for the WhatsApp Connect action.

    :param router: The Streamlit Router object.
    :param agent_id: The ID of the agent.
    :param action_id: The ID of the action.
    :param info: A dictionary containing information about the action.
    """
    (model_key, module_root) = app_header(agent_id, action_id, info)

    with st.expander("WPPConnect Configuration", expanded=False):
        # Add main app controls
        app_controls(agent_id, action_id)
        # Add update button to apply changes
        app_update_action(agent_id, action_id)

    with st.expander("Export Outbox", False):
        if st.button(
            "Export Outbox",
            key=f"{model_key}_btn_export_outbox",
            disabled=(not agent_id),
        ):
            # Call the function to purge
            if result := call_action_walker_exec(
                agent_id, module_root, "export_outbox", {}
            ):
                if result:
                    result = json.dumps(result, indent=2)
                    st.download_button(
                        label="Download Exported Outbox",
                        data=result,
                        file_name="exported_outbox.json",
                        mime="application/json",
                    )
                    st.success("Export outbox successfully")
                    st.json(result)
            else:
                st.error(
                    "Failed to export putbox. Ensure that there is something to export"
                )

    with st.expander("Import Outbox", False):
        outbox_source = st.radio(
            "Choose data source:",
            ("Text input", "Upload file"),
            key=f"{model_key}_outbox_source",
        )

        raw_text_input = ""
        uploaded_file = None
        data_to_import = None

        if outbox_source == "Text input":
            raw_text_input = st.text_area(
                "Outbox in YAML or JSON",
                value="",
                height=170,
                key=f"{model_key}_outbox_data",
            )

        if outbox_source == "Upload file":
            uploaded_file = st.file_uploader(
                "Upload file (YAML or JSON)",
                type=["yaml", "json"],
                key=f"{model_key}_agent_outbox_upload",
            )

        purge_collection = st.checkbox(
            "Purge Collection", value=False, key=f"{model_key}_purge_collection"
        )

        if st.button(
            "Import Outbox",
            key=f"{model_key}_btn_import_outbox",
            disabled=(not agent_id),
        ):
            try:
                if outbox_source == "Upload file" and uploaded_file:
                    file_content = uploaded_file.read().decode("utf-8")
                    if uploaded_file.type == "application/json":
                        data_to_import = json.loads(file_content)
                    else:
                        data_to_import = yaml.safe_load(file_content)

                elif outbox_source == "Text input" and raw_text_input.strip():
                    # Try JSON first, fall back to YAML
                    try:
                        data_to_import = json.loads(raw_text_input)
                    except json.JSONDecodeError:
                        data_to_import = yaml.safe_load(raw_text_input)

                if data_to_import is None:
                    st.error("No valid outbox data provided.")
                else:
                    outbox = {}
                    outbox = data_to_import.get("outbox", data_to_import)

                    result = call_action_walker_exec(
                        agent_id,
                        module_root,
                        "import_outbox",
                        {"outbox": outbox, "purge_collection": purge_collection},
                    )
                    if result:
                        st.success("Import outbox successfully")
                    else:
                        st.error(
                            "Failed to import outbox. Ensure that there is something to import."
                        )
            except Exception as e:
                st.error(f"Import failed: {e}")

    # Unique keys in session state for button control and data
    session_payload_key = "wppconnect_payload"

    def get_wppconnect_status() -> None:
        """Call and store the latest status in session state."""
        result = call_action_walker_exec(agent_id, module_root, "register_session", {})
        st.session_state[session_payload_key] = result or {}

    def logout_wppconnect() -> None:
        call_action_walker_exec(agent_id, module_root, "logout_session", {})
        st.session_state.pop(session_payload_key, None)
        # Optionally store a notification or feedback flag

    def close_wppconnect() -> None:
        call_action_walker_exec(agent_id, module_root, "close_session", {})
        st.session_state.pop(session_payload_key, None)
        # Optionally store a notification or feedback flag

    # initialize the session state for wppconnect status
    if session_payload_key not in st.session_state:
        get_wppconnect_status()
        st.rerun()

    result = st.session_state.get(session_payload_key, {})

    with st.expander("WPPConnect Session Registration", expanded=True):

        if result == {} or result.get("status") == "ERROR":
            st.error(
                f"{result.get("message", "Session registration error.")} Check your WPPConnect Configuration and try again.",
                icon="❌",
            )
            if st.button("Refresh", key="refresh_registration_btn"):
                with st.spinner("Refreshing session..."):
                    get_wppconnect_status()
                    st.rerun()
            st.stop()

        # Main logic block follows your requirements
        if result.get("status") == "CONNECTED":
            # Step 2: Show connected + message + Logout button
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

            # Center the Logout button
            st.markdown(
                '<div style="display:flex; justify-content:center;">',
                unsafe_allow_html=True,
            )

            col1, col2, col3, col4, col5, col6 = st.columns([1, 1, 3, 3, 2, 2])
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

        elif result.get("status") == "INITIALIZING":
            # Status is INITIALIZING and qrcode is not ready
            st.warning(
                "Session is initializing. Please wait a moment. Click 'Refresh' to update status. If too much time elapses, click 'Close Session' to start again",
                icon="ℹ️",
            )
            st.markdown("<br>", unsafe_allow_html=True)

            col1, col2, col3, col4, col5, col6 = st.columns([1, 1, 3, 3, 2, 2])
            with col1:
                if st.button("Refresh", key="init_refresh_session_btn"):
                    with st.spinner("Refreshing session..."):
                        get_wppconnect_status()
                        st.rerun()

            with col2:
                if st.button("Close", key="init_close_session_btn"):
                    with st.spinner("Closing session..."):
                        close_wppconnect()
                        st.rerun()

                # Auto-refresh every 5 seconds
                st.rerun = getattr(st, "rerun", None)
                if st.rerun:
                    time.sleep(5)
                    get_wppconnect_status()
                    st.rerun()

        else:
            qrcode = result.get("qrcode", "")
            if not qrcode:
                # Status is not CONNECTED and qrcode is missing or empty
                st.info(
                    "Session is not connected. Start a new session to get the QR Code.",
                    icon="ℹ️",
                )
                st.markdown("<br>", unsafe_allow_html=True)

                col1, col2, col3, col4, col5, col6 = st.columns([1, 1, 3, 3, 2, 2])
                with col1:
                    if st.button("Start", key="not_qr_start_session_btn"):
                        with st.spinner("Starting session..."):
                            get_wppconnect_status()
                            st.rerun()

            else:
                # qrcode exists: show QR image and refresh
                st.info(
                    result.get(
                        "message",
                        "Scan the QR code to connect your WhatsApp account.",
                    ),
                    icon="ℹ️",
                )
                try:
                    # autocorrect the base64 qrcode
                    if not qrcode.startswith("data:image/png;base64,"):
                        qrcode = f"data:image/png;base64,{qrcode}"
                    # Display the QR code centered
                    st.markdown(
                        f"""
                        <div style="display: flex; justify-content: center;">
                            <img src="{qrcode}" width="500">
                        </div>
                        """,
                        unsafe_allow_html=True,
                    )
                except Exception as ex:
                    st.error(f"There was an error rendering the QR code., {str(ex)}")

                col1, col2, col3, col4, col5, col6 = st.columns([1, 1, 3, 3, 2, 2])
                with col1:
                    if st.button("Refresh", key="refresh_qr_btn"):
                        with st.spinner("Refreshing QR code..."):
                            get_wppconnect_status()
                            st.rerun()

                with col2:
                    if st.button("Close", key="qr_close_session_btn"):
                        with st.spinner("Closing session..."):
                            close_wppconnect()
                            st.rerun()

                # Auto-refresh every 5 seconds
                st.rerun = getattr(st, "rerun", None)
                if st.rerun:
                    time.sleep(5)
                    get_wppconnect_status()
                    st.rerun()
