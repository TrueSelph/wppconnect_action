"""This module contains the Streamlit app for the WhatsApp Connect action."""

import json
import time
from contextlib import suppress

import pandas as pd
import streamlit as st
import yaml
from jvclient.lib.utils import call_api
from jvclient.lib.widgets import app_controls, app_header, app_update_action
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
            result = call_api(
                endpoint="action/walker/wppconnect_action/export_outbox",
                json_data={"agent_id": agent_id},
            )

            if result and result.status_code == 200:
                json_result = result.json()
                outbox_result = json_result.get("reports", [{}])[0]

                if outbox_result:
                    st.download_button(
                        label="Download Exported Outbox",
                        data=json.dumps(outbox_result, indent=2),
                        file_name="exported_outbox.json",
                        mime="application/json",
                    )
                    st.success("Export outbox successfully")
                    st.json(outbox_result)
                else:
                    st.error(
                        "Failed to export outbox. Ensure that there is something to export"
                    )
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

                    result = call_api(
                        endpoint="action/walker/wppconnect_action/import_outbox",
                        json_data={
                            "agent_id": agent_id,
                            "outbox": outbox,
                            "purge_collection": purge_collection,
                        },
                    )
                    if result and result.status_code == 200:
                        st.success("Import outbox successfully")
                    else:
                        st.error(
                            "Failed to import outbox. Ensure that there is something to import."
                        )
            except Exception as e:
                st.error(f"Import failed: {e}")

    with st.expander("Purge Outbox", False):
        job_id = st.text_input(
            "Item ID to purge",
            value="",
            key=f"{model_key}_item_id",
        )

        if job_id:
            button_text = "Yes, Purge outbox item"
            message = "Outbox item purged successfully"
            confirm_message = "Are you sure you want to purge the outbox item? This action cannot be undone."
        else:
            button_text = "Yes, Purge outbox"
            message = "Outbox purged successfully"
            confirm_message = "Are you sure you want to purge the outbox? This action cannot be undone."

        # Step 1: Trigger confirmation
        if st.button("Purge", key=f"{model_key}_btn_purge_outbox_item"):
            st.session_state.confirm_purge_collection = True
            st.session_state.purge_outbox_item = None  # Clear any previous result

        # Step 2: Handle confirmation prompt
        if st.session_state.get("confirm_purge_collection", False):
            st.warning(
                confirm_message,
                icon="⚠️",
            )
            col1, col2 = st.columns(2)

            with col1:
                if st.button(button_text):
                    result = call_api(
                        endpoint="action/walker/wppconnect_action/purge_outbox",
                        json_data={"agent_id": agent_id, "job_id": job_id},
                    )
                    if result and result.status_code == 200:
                        json_result = result.json()
                        purge_outbox_item = json_result.get("reports", [{}])[0]

                        st.session_state.purge_outbox_item = purge_outbox_item
                        st.session_state.confirm_purge_collection = False
                    else:
                        st.session_state.confirm_purge_collection = False
                        st.session_state.purge_outbox_item = None

            with col2:
                if st.button("no, cancel"):
                    st.session_state.confirm_purge_collection = False
                    st.session_state.purge_outbox_item = None
                    st.rerun()

        # Step 3: Show result *outside* confirmation
        purge_outbox_item = st.session_state.get("purge_outbox_item")
        if purge_outbox_item:
            st.success(message)
            st.session_state.purge_outbox_item = None  # Reset after showing
            time.sleep(2)
            st.rerun()
        elif purge_outbox_item in [False, []]:
            st.error(
                "Failed to purge outbox. Ensure that there is something to purge or check functionality"
            )
            st.session_state.purge_outbox_item = None  # Reset after showing
            time.sleep(2)
            st.rerun()

    # Unique keys in session state for button control and data
    session_payload_key = "wppconnect_payload"

    def get_wppconnect_status() -> None:
        """Call and store the latest status in session state."""
        st.session_state[session_payload_key] = {}

        result = call_api(
            endpoint="action/walker/wppconnect_action/register_session",
            json_data={"agent_id": agent_id},
        )
        if result and result.status_code == 200:
            json_result = result.json()
            st.session_state[session_payload_key] = json_result.get("reports", [{}])[0]

    def logout_wppconnect() -> None:
        """Logout session state."""
        result = call_api(
            endpoint="action/walker/wppconnect_action/logout_session",
            json_data={"agent_id": agent_id},
        )
        if result and result.status_code == 200:
            st.session_state.pop(session_payload_key, None)

    def close_wppconnect() -> None:
        """Close session state."""
        result = call_api(
            endpoint="action/walker/wppconnect_action/close_session",
            json_data={"agent_id": agent_id},
        )
        if result and result.status_code == 200:
            st.session_state.pop(session_payload_key, None)

    # initialize the session state for wppconnect status
    if session_payload_key not in st.session_state:
        get_wppconnect_status()
        st.rerun()

    result = st.session_state.get(session_payload_key, {})

    with st.expander("WPPConnect Session Registration", expanded=True):

        if result == {}:
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

        elif (
            result.get("status") == "INITIALIZING"
            and not result.get("details").get("qrcode")
            or result.get("status") == "AWAITING_QRSCAN"
            and not result.get("qrcode")
        ):
            # Status is INITIALIZING and qrcode is not ready
            st.warning(
                "Session is initializing. Please wait a moment. Click 'Refresh' to update status. If too much time elapses, click 'Close Session' to start again",
                icon="ℹ️",
            )
            st.markdown("<br>", unsafe_allow_html=True)

            col1, col2, col3 = st.columns([2, 2, 10])
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
                qrcode = result.get("details", {}).get("qrcode")

            if not qrcode:
                # Status is not CONNECTED and qrcode is missing or empty
                st.info(
                    "Session is not connected. Start a new session to get the QR Code.",
                    icon="ℹ️",
                )
                st.markdown("<br>", unsafe_allow_html=True)

                col1, col2, col3 = st.columns([2, 2, 10])
                with col1:
                    if st.button("Start", key="not_qr_start_session_btn"):
                        with st.spinner("Starting session..."):
                            get_wppconnect_status()
                            st.rerun()

            else:

                st.info(
                    "Scan the QR code to connect your WhatsApp account.",
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

                col1, col2, col3 = st.columns([2, 2, 10])
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

    with st.expander("Outbox", True):
        # Initialize session state variables for pagination
        if "current_page" not in st.session_state:
            st.session_state.current_page = 1
        if "per_page" not in st.session_state:
            st.session_state.per_page = 10
        if "job_id" not in st.session_state:
            st.session_state.job_id = []
        if "status" not in st.session_state:
            st.session_state.status = []

        args = {
            "agent_id": agent_id,
            "page": st.session_state.current_page,
            "limit": st.session_state.per_page,
            "filtered_job_id": st.session_state.job_id,
            "filtered_status": st.session_state.status,
        }

        # Fetch documents with pagination parameters
        result = call_api(
            endpoint="action/walker/wppconnect_action/list_outbox_items", json_data=args
        )

        if result.status_code == 200:
            json_result = result.json()
            data = json_result.get("reports", [{}])[0]

            # Use the total_items from the API response, not the length of current items
            total_items = data.get("total_items", 0)
            total_pages = data.get("total_pages", 1)

            df = prepare_data(data["items"])

            # Combine date and time columns if they exist
            if "date" in df.columns and "time" in df.columns:
                df["datetime"] = df["date"].astype(str) + " " + df["time"].astype(str)
                # Convert to datetime if needed pass
                with suppress(Exception):
                    df["datetime"] = pd.to_datetime(df["datetime"])

            if not df.empty:
                # Create columns for filters

                col1, col2, col3 = st.columns(3)

                with col1:
                    prev_status_filter = st.session_state.status
                    # Status filter - empty by default shows all
                    status_filter = st.multiselect(
                        "Filter by status",
                        options=sorted(["FAILED", "PENDING", "PROCESSED"]),
                        default=(
                            st.session_state.status if st.session_state.status else []
                        ),
                    )
                    st.session_state.status = status_filter

                    # If status changed, trigger a rerun
                    if status_filter != prev_status_filter:
                        st.rerun()

                with col2:
                    prev_batch_filter = st.session_state.job_id
                    # Batch ID filter - empty by default shows all
                    batch_filter = st.multiselect(
                        "Filter by Job ID",
                        options=sorted(data["jobs"]),
                        default=(
                            st.session_state.job_id if st.session_state.job_id else []
                        ),
                    )
                    st.session_state.job_id = batch_filter
                    # If job_id changed, trigger a rerun
                    if batch_filter != prev_batch_filter:
                        st.rerun()

                with col3:
                    # Store previous per_page value
                    prev_per_page = st.session_state.per_page

                    # Per-page selection dropdown
                    per_page = st.selectbox(
                        "Items per page",
                        options=[5, 10, 20, 50, 100, 200],
                        index=[5, 10, 20, 50, 100, 200].index(
                            st.session_state.per_page
                        ),
                        key="per_page_selector",
                        on_change=lambda: setattr(st.session_state, "current_page", 1),
                    )
                    # Update per_page in session state
                    st.session_state.per_page = per_page

                    # If per_page changed, trigger a rerun
                    if per_page != prev_per_page:
                        st.rerun()

                # Apply filters
                df_filtered = df.copy()

                # Display the data with adjusted column widths
                st.dataframe(
                    df_filtered[
                        [
                            "id",
                            "session_id",
                            "content",
                            "message_type",
                            "status",
                            "datetime",
                        ]
                    ],
                    column_config={
                        "id": "Message ID",
                        "session_id": "Session ID",
                        "content": st.column_config.TextColumn(
                            "Content", width="large"
                        ),
                        "message_type": "Type",
                        "status": st.column_config.TextColumn("Status", width="small"),
                        "datetime": "Date & Time",
                    },
                    hide_index=True,
                    use_container_width=True,
                )

                # Pagination controls at the bottom
                col1, col2, col3 = st.columns([2, 4, 2])

                with col1:
                    if st.session_state.current_page > 1:
                        if st.button("⬅️ Previous Page"):
                            st.session_state.current_page -= 1
                            st.rerun()
                    else:
                        st.button("⬅️ Previous Page", disabled=True)

                with col2:
                    # Centered pagination info
                    st.markdown(
                        f"<div style='text-align: center;'>Showing {len(df_filtered)} of {total_items} messages (Page {st.session_state.current_page} of {total_pages})</div>",
                        unsafe_allow_html=True,
                    )

                with col3:
                    if st.session_state.current_page < total_pages:
                        if st.button("Next Page ➡️"):
                            st.session_state.current_page += 1
                            st.rerun()
                    else:
                        st.button("Next Page ➡️", disabled=True)

                # Message statistics
                st.write("---")
                st.subheader("Message Statistics")

                col1, col2, col3, col4 = st.columns(4)
                with col1:
                    st.metric("Total Messages", total_items)
                with col2:
                    st.metric(
                        "Processed Messages", len(df[df["status"] == "PROCESSED"])
                    )
                with col3:
                    st.metric("Pending Messages", len(df[df["status"] == "PENDING"]))
                with col4:
                    st.metric("Failed Messages", len(df[df["status"] == "FAILED"]))
            else:
                st.warning("No outbox messages found")
        else:
            st.warning("No outbox items found")


def prepare_data(data: dict) -> pd.DataFrame:
    """
    Transforms a list of message dictionaries into a pandas DataFrame, extracting
    relevant fields and converting date and time information.

    Args:
        data (list): A list of dictionaries, each representing a message with fields
                     such as 'job_id', 'item_id', 'status', 'session_id', 'message',
                     and 'added_at'.

    Returns:
        pandas.DataFrame: A DataFrame containing the extracted message data with
                          additional columns for date and time if available.
    """

    all_items = []

    for message in data:
        item = {
            "job_id": message["job_id"],
            "id": message["item_id"],
            "status": message["status"],
            "session_id": message["session_id"],
            "message_type": message["message"]["message_type"],
            "content": message["message"]["content"],
            "added_at": message["added_at"],
        }
        all_items.append(item)
    df = pd.DataFrame(all_items)

    if not df.empty:
        # Convert datetime
        df["added_at"] = pd.to_datetime(df["added_at"])
        df["date"] = df["added_at"].dt.date
        df["time"] = df["added_at"].dt.time

    return df
