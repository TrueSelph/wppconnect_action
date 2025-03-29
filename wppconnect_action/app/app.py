"""This module contains the Streamlit app for the WhatsApp Connect action."""

import base64
from io import BytesIO

import streamlit as st
from jvcli.client.lib.utils import call_action_walker_exec
from jvcli.client.lib.widgets import app_controls, app_header, app_update_action
from PIL import Image
from streamlit_router import StreamlitRouter


def render(router: StreamlitRouter, agent_id: str, action_id: str, info: dict) -> None:
    """
    Render the Streamlit app for the WhatsApp Connect action.

    This app consists of the following components:

    1. Header controls (via app_header)
    2. Main controls (via app_controls)
    3. Webhook registration (via register_wppconnect_webhook)
    4. Webhook logout (via logout_wppconnect)
    5. Update button to apply changes (via app_update_action)

    :param router: The Streamlit Router object.
    :param agent_id: The ID of the agent.
    :param action_id: The ID of the action.
    :param info: A dictionary containing information about the action.
    """
    (model_key, module_root) = app_header(agent_id, action_id, info)

    # Add main app controls
    app_controls(agent_id, action_id)

    with st.expander("Register Webhook", expanded=True):
        st.markdown("### Webhook Registration")
        st.markdown(
            "Click the button below to register the webhook. "
            "This enables your agent to communicate with WhatsApp."
        )

        # Create two columns for the buttons
        col1, col2 = st.columns(2)

        with col1:
            if st.button("Register Webhook", key=f"{model_key}_btn_register_webhook"):
                with st.spinner("Registering webhook..."):
                    result = call_action_walker_exec(
                        agent_id, module_root, "register_wppconnect_webhook", {}
                    )

                if result["status"] == "QRCODE":
                    st.success("Please scan the QR code to connect")
                    try:
                        # Decode the Base64-encoded QR code
                        qr_code_bytes = BytesIO(base64.b64decode(result["qr_code"]))
                        qr_code_image = Image.open(qr_code_bytes)

                        # Store QR code image in session state
                        st.session_state["qr_code_image"] = qr_code_image

                        # Display the QR code centered
                        st.markdown(
                            f"""
                            <div style="display: flex; justify-content: center;">
                                <img src="data:image/png;base64,{result['qr_code']}" width="500">
                            </div>
                            """,
                            unsafe_allow_html=True,
                        )

                        # Add success state
                        st.session_state["qr_code_success"] = True
                    except Exception as e:
                        st.error(f"Failed to process QR code image: {str(e)}")
                        st.error(f"{result}")
                        st.session_state["qr_code_success"] = False

                elif result:
                    st.success("Webhook registered successfully!")
                else:
                    st.error("Failed to register webhook. Please try again.")

        with col2:
            if st.button("Logout Webhook", key=f"{model_key}_btn_logout_webhook"):
                with st.spinner("Logging out..."):
                    logout_result = call_action_walker_exec(
                        agent_id, module_root, "logout_wppconnect", {}
                    )

                if logout_result == []:
                    st.success("Logged out successfully!")
                else:
                    st.error("Failed to log out. Please try again.")

    # Add update button to apply changes
    app_update_action(agent_id, action_id)
