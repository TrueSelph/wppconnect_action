import os;
import uuid;
import shutil;
import logging;
import traceback;
import base64;
import random;
import from datetime { datetime, timezone }
import dateutil.parser;
import from typing { Union }
import from logging { Logger }
import from .modules.wppconnect_api { WPPConnectAPI }
import from actions.jivas.wppconnect_action.media_collection { MediaCollection }
import from jivas.agent.modules.text.chunking { chunk_long_message }
import from jivas.agent.memory.collection { Collection }
import from jivas.agent.action.action { Action }
import from jivas.agent.memory.interaction_response {
    MessageType, InteractionMessage, TextInteractionMessage, MediaInteractionMessage, MultiInteractionMessage
}
import from jac_cloud.plugin.jaseci { JacPlugin as Jac }
import from jivas.agent.core.graph_node { GraphNode }
import from .wppconnect_interact { wppconnect_interact }
import from jac_cloud.core.archetype { BaseCollection, NodeAnchor, WalkerAnchor }
import from jivas.agent.modules.data.node_pager { NodePager }
import from jivas.agent.modules.system.common { node_obj }
import from jivas.agent.modules.data.node_get { node_get }
import from jivas.agent.modules.data.commit { commit }
import from jivas.agent.action.interact { interact }


node WPPConnectAction(Action) {
    # houses configurations per agent for whatsapp api communications provided by wppconnect api

    # set up logger
    static has logger:Logger = logging.getLogger(__name__);

    has api_url:str = ""; # WPPConnect Server URL
    has secret_key:str = ""; # WPPConnect Server Secret Key
    has token:str = ""; # WPPConnect Server API Key for this session
    has session:str = ""; # WPPConnect Server Instance ID
    has base_url:str = ""; # Jivas Base URL
    has pulse_interval:int = 2; # pulse interval in seconds
    has media_collecion_autoclose_window:int = 5; # autoclose window in seconds
    # API settings
    has webhook_url:str = ""; # JIVAS webhook for WPPConnect
    has webhook_token_expiry_days: int = 60; # the number of days for webhook token validity
    has request_timeout:float = 10.0; # the length of time this action waits for api to complete request
    has chunk_length:int = 1024; # max length of message to send
    has use_pushname:bool = True; # use the WhatsApp push name as the user name
    has ignore_newsletters:bool = True; # ignore newsletters
    has ignore_forwards:bool = True; # ignore forwarded messages
    has sync_pushname:bool = True; # set Agent name as pushname
    has sync_avatar:bool = True; # set Agent avatar (if present and set) as profile pic
    # poll settings
    has poll_manager_action:str = "PollManagerInteractAction"; # the label of the poll manager action to use for polls


    def postinit {
        super.postinit();
        # list of node attributes which should be excluded from export
        self.transient_attrs += ['media_monitor_id', 'token'];
    }

    def on_enable() {
        self.on_register();
    }

    def on_register {

        if (not self.api_url) {
            # set secret_key for wpp in environment
            self.api_url = os.environ.get('WPP_API_URL', 'http://localhost:21465/api');
        }

        if (not self.base_url) {
            # default to jivas base url in environment
            self.base_url = os.environ.get('JIVAS_BASE_URL');
        }

        if (not self.secret_key) {
            # set secret_key for wpp in environment
            self.secret_key = os.environ.get('WPP_SECRET_KEY', 'THISISMYSECURETOKEN');
        }

        if(not self.session) {
            agent_name = self.get_agent().name;
            agent_name = agent_name.replace(" ", "_");
            agent_name = agent_name.replace("-", "_");
            self.session = agent_name;
        }
    }

    def post_register() {
        self.webhook_url = "";
        self.register_session(auto_register=True);
    }

    def pulse() {
        self.autoclose_media_collections();
    }

    def healthcheck() -> Union[bool, dict] {
        try {
            if(not self.api_url) {
                return {
                    "status": False,
                    "message": "API URL is not set.",
                    "severity": "error"
                };
            }

            if( result := self.api().check_connection() ) {
                if 'error' in result.keys() {
                    return {
                        "status": False,
                        "message": result.get('error'),
                        "severity": "error"
                    };
                }
                if('status' in result.keys()) {
                    status = result.get('status');
                    if not status {
                        return {
                            "status": status,
                            "message": result.get('message'),
                            "severity": "warning"
                        };
                    } else {
                        return True;
                    }
                }
            }
            return False;
        } except Exception as e {
            self.logger.error(f"An exception occurred in {self.label}: \n{traceback.format_exc()}\n");
            return {
                "status": False,
                "message": "There was an error : {e}",
                "severity": "error"
            };
        }
    }

    # --------------- WPPConnectAPI ----------------

    def api() -> WPPConnectAPI {
        # load the api instance

        return WPPConnectAPI(
            api_url=self.api_url,
            session=self.session,
            token=self.token,
            secret_key=self.secret_key,
            timeout=self.request_timeout
        );

    }

    def register_session(auto_register:bool = False) -> dict {
        # setup procedure for webhook registration on api

        result = {};

        # evaluate session status
        status_result = self.api().status();
        session_status = status_result.get("status", "").upper();
        # if connected, return session result details
        if session_status == "CONNECTED" and self.webhook_url {
            return self.api().register_session(webhook_url = self.webhook_url, wait_qr_code = False);
        }

        if not self.webhook_url {
            if session_status == "CONNECTED" {
                self.api().close_session();
            }
            # if the session is not connected, proceed with re-registration with webhook
            webhook_walker = wppconnect_interact(agent_id=self.get_agent().id);
            callback_url = webhook_walker.get_callback_url(
                base_url=self.base_url,
                agent_id=self.get_agent().id,
                expiration = self.webhook_token_expiry_days
            );

            if not callback_url {
                self.logger.error('unable to generate webhook url for WPPConnect, missing required parameters');
                return {};
            }
            # update the webhook URL
            self.webhook_url = callback_url;
            # complete the full webhook url
            self.logger.debug(f'wppconnect webhook url: {self.webhook_url}');
        }
        result = self.api().register_session(webhook_url = self.webhook_url, wait_qr_code = True, auto_register = auto_register);

        if result is not None and result.get('status') != 'ERROR' {
            # check if the response contains a valid token
            if result.get('token') {
                self.token = result.get('token');
                # remove the token from the payload now that we've saved it
                del result['token'];
            }
            if result.get("status") == "CONNECTED" {
                # attempt to set username
                if(self.sync_pushname) {
                    self.api().change_username(self.get_agent().name);
                }

                # if there is an avatar set this as well
                if( self.sync_avatar and (avatar_action := self.get_agent().get_action('AvatarAction')) ) {
                    if avatar_base64 := avatar_action.get_avatar_image(with_prefix=False) {
                        avatar_bytes = base64.b64decode(avatar_base64);
                        self.api().set_profile_pic(file_data=avatar_bytes);
                    }
                }
            }
        }

        return result;
    }

    def logout_session() {
        self.api().logout_session();
        return True;
    }

    def sanitize_message(message:str) {
        return message.replace("**", "*").replace("<br/>", "\n").replace("<b>", "*").replace("</b>", "*");
    }

    def send_message(session_id:str, message:InteractionMessage, is_group:bool = False, parent_message_id:str = "") -> dict {
        # processes an agent response payload format and sends an wppconnect message to a specified session_id via the action
        result = {};

        if(message and session_id) {

            if(not parent_message_id) {
                parent_message_id = message.data_get('parent_message_id');
            }

            if (message.get_type() == MessageType.SILENCE.value) {}
            elif(message.get_type() == MessageType.TEXT.value) {
                content = self.sanitize_message(message = message.get_content());
                outgoing = chunk_long_message(message=content, max_length = self.chunk_length, chunk_length = self.chunk_length);

                for chunk in outgoing {
                    result = self.api().send_message(phone=session_id, message=chunk, is_group=is_group, message_id=parent_message_id);
                }


            } elif(message.get_type() == MessageType.MEDIA.value) {
                file_type = WPPConnectAPI.get_file_type(mime_type=message.mime);
                content = self.sanitize_message(message = message.get_content());
                if(file_type.get('file_type') == "poll"){
                    result = self.api().send_poll_message(phone=session_id, name=message.data.get('name'), choices=message.data.get('choices'), options=message.data.get('options'), is_group=is_group);

                    # update with poll manager action
                    if((poll_manager_action := self.get_agent().get_action(action_label=self.poll_manager_action)) and (result["status"] == "success")) {
                        # set options
                        poll_options = message.data.get('options', None);
                        poll_options["duration_minutes"] = message.data.get('duration_minutes', None); # default to None if not set

                        poll_group_id = poll_manager_action.register_dispatched_poll_instance(
                            user_session_id=session_id,
                            poll_definition={"name": message.data.get('name'), "choices": message.data.get('choices'), "options": poll_options}, # {"name", "choices", "options": {"selectableCount", "duration_minutes"} }
                            whatsapp_poll_id=result["response"][0]["id"], # ID of the WA message containing the poll
                            preferred_internal_id=message.data.get('id') if message.data.get('id') else message.data.get('preferred_internal_id'), # Use the poll id as the preferred internal ID else default to preferred_internal_id
                        );

                        result["internal_poll_group_id"] = poll_group_id; # add the poll group id to the result
                    }

                }elif(file_type.get('file_type') in ["document", "video", "unknown"]) {
                    result = self.api().send_file(phone= session_id, file_url=message.data.get('url'), filename=message.data.get('file_name'), caption = content, is_group=is_group);
                } elif(file_type.get('file_type') == "image") {
                    result = self.api().send_image(phone=session_id, file_url= message.data.get('url'), filename=message.data.get('file_name'), caption = content, is_group=is_group);
                }
            } elif(message.get_type() == MessageType.MULTI.value) {
                for message_item in message.get_content_items() {
                    if(message_item.get_type() == MessageType.TEXT.value) {
                        content = self.sanitize_message(message = message_item.get_content());
                        outgoing = chunk_long_message(message=content, max_length = self.chunk_length, chunk_length = self.chunk_length);
                        for chunk in outgoing {
                            result = self.api().send_message(phone=session_id, message=chunk, is_group=is_group, message_id=parent_message_id);
                        }
                    } elif(message_item.get_type() == MessageType.MEDIA.value) {
                        file_type = WPPConnectAPI.get_file_type(mime_type=message_item.mime);
                        content = self.sanitize_message(message = message_item.get_content());
                        if(file_type.get('file_type') == "poll"){
                            result = self.api().send_poll_message(phone=session_id, name=message_item.data.get('name'), choices=message_item.data.get('choices'), options=message_item.data.get('options'), is_group=is_group);

                            # update with poll manager action
                            if((poll_manager_action := self.get_agent().get_action(action_label=self.poll_manager_action)) and (result["status"] == "success")) {
                                # set options
                                poll_options = message_item.data.get('options', None);
                                poll_options["duration_minutes"] = message_item.data.get('duration_minutes', None); # default to 60 minutes if not set

                                poll_group_id = poll_manager_action.register_dispatched_poll_instance(
                                    user_session_id=session_id,
                                    poll_definition={"name": message_item.data.get('name'), "choices": message_item.data.get('choices'), "options": poll_options}, # {"name", "choices", "options": {"selectableCount", "duration_minutes"} }
                                    whatsapp_poll_id=result["response"][0]["id"], # ID of the WA message containing the poll
                                    preferred_internal_id=message_item.data.get('id') if message_item.data.get('id') else message_item.data.get('preferred_internal_id'), # Use the poll id as the preferred internal ID if any else default to preferred_internal_id
                                );

                                result["internal_poll_group_id"] = poll_group_id; # add the poll group id to the result
                            }
                        }elif(file_type.get('file_type') in ["document", "video", "unknown"]) {
                            result = self.api().send_file(phone= session_id, file_url=message_item.data.get('url'), filename=message_item.data.get('file_name'), caption = content, is_group=is_group);
                        } elif(file_type.get('file_type') == "image") {
                            result = self.api().send_image(phone=session_id, file_url= message_item.data.get('url'), filename=message_item.data.get('file_name'), caption = content, is_group=is_group);
                        }
                    }
                }
            }
        }

        return result;
    }

    def broadcast_message(message:InteractionMessage, ignore_list:list = []) -> str {
        # processes an agent response payload format and sends a message to all session_ids via the action

        agent_node = self.get_agent();
        job_id = str(uuid.uuid4());

        if((frames := agent_node.get_memory().get_frames()) and (outbox_action := self.get_agent().get_action(action_label="OutboxAction"))) {
            # get all frames then proceed to broadcast
            for frame_node in frames {
                if(frame_node.session_id not in ignore_list) {
                    if(interaction_node := frame_node.get_last_interaction()) {
                        if interaction_node.channel in ['whatsapp'] {
                            # add the message to the outbox
                            messages = [{
                                "to": frame_node.session_id,
                                "message": message,
                                "channel": "whatsapp"
                            }];
                            outbox_action.add_outbox_job(sender_action=self.get_type(), callback_url=self.webhook_url, messages=messages);
                        }
                    }
                }
            }
            return job_id;
        }

        return None;
    }

    # --------------- MEDIA MONITOR ----------------

    def start_pulse() {
        # Proceed with scheduler start
        if pulse_action := self.get_agent().get_action(action_label="PulseAction") {
            pulse_action.add_schedule(
                self.get_type(),
                f'every({self.pulse_interval}).seconds'
            );
        }
    }

    def stop_pulse() {
        # stop the scheduler
        if(pulse_action := self.get_agent().get_action(action_label="PulseAction")) {
            # remove the scheduler from the pulse action
            pulse_action.remove_schedule(self.get_type());
        }
    }

    def monitor_media() {
        # start the pulse if not already running to monitor and autoclose media collections for users
        self.start_pulse();
    }

    def send_media_upload_event(session_id:str, media_collection:MediaCollection) {
        # triggers interact to initiate processing of async uploaded media

        agent_node = self.get_agent();
        frame_node = agent_node.get_memory().get_frame(agent_id = agent_node.id, session_id = session_id, force_session=True);

        message = (root spawn interact(
            utterance = "I've sent media in the chat",
            agent_id = agent_node.id,
            session_id = session_id,
            verbose = False,
            reporting = False,
            channel = "whatsapp",
            data = {"whatsapp_media": media_collection.export_media_items()}
        )).message;

        self.send_message(session_id=session_id, message=message);

        # let's disable the typing
        self.api().set_typing_status(phone=session_id, value=False);

        # let's clean up..remove the media collection
        media_collection.delete();
    }

    def get_open_media_collection(session_id:str, create:bool=False) -> MediaCollection {
        # Returns an existing open media collection for the session, or creates a new one if none exists.
        collection = self.get_collection();

        media_collection = node_obj(node_get({
            "name": "MediaCollection",
            "archetype.collection_id": collection.id,
            "archetype.session_id": session_id,
            "archetype.status": "OPEN"
        }));

        if not media_collection and create {
            media_collection = MediaCollection(collection_id=collection.id, session_id=session_id);
            collection ++> media_collection;
            commit(media_collection);
        }

        return media_collection;
    }

    def get_recent_media_collection(session_id:str) -> MediaCollection {
        # Returns the most recently closed media collection for the session.
        collection = self.get_collection();

        media_collections = node_get({
            "name": "MediaCollection",
            "archetype.collection_id": collection.id,
            "archetype.session_id": session_id,
            "archetype.status": "CLOSED"
        });

        if isinstance(media_collections, list) and len(media_collections) > 0 {
            ::py::
            media_collections.sort(key=lambda mc: getattr(mc, "created_on", ""), reverse=True)
            ::py::
            return media_collections[0];
        } elif media_collections {
            return node_obj(media_collections);
        }

        return None;
    }

    def get_media_collections(session_id:str) -> list {
        # Returns all media collections for the session.
        collection = self.get_collection();

        media_collections = node_get({
            "name": "MediaCollection",
            "archetype.collection_id": collection.id,
            "archetype.session_id": session_id
        });

        return media_collections if media_collections else [];
    }

    def close_media_collection(session_id:str) -> bool {
        # Closes the open media collection for the session, if any.
        if media_collection := self.get_open_media_collection(session_id=session_id) {
            media_collection.close_collection();
            self.send_media_upload_event(session_id=media_collection.session_id, media_collection=media_collection);
            self.logger.info(f"Closed media collection for session: {session_id}");
            return True;
        }
        return False;
    }

    def autoclose_media_collections() {
        # Autocloses open media collections that have exceeded the autoclose window.
        collection = self.get_collection();
        open_media_collections = node_get({
            "name": "MediaCollection",
            "archetype.collection_id": collection.id,
            "archetype.status": "OPEN"
        });

        if not open_media_collections {
            self.stop_pulse();
            return;
        }

        now = datetime.now(timezone.utc);

        for mc_obj in open_media_collections {
            updated_on = getattr(mc_obj, "updated_on", None);
            if updated_on {
                try {
                    updated_dt = dateutil.parser.parse(updated_on);
                    window = self.media_collecion_autoclose_window;
                    if (now - updated_dt).total_seconds() > window {
                        mc_obj.close_collection();
                        self.send_media_upload_event(session_id=mc_obj.session_id, media_collection=mc_obj);
                        self.logger.info(f"Autoclosed media collection for session: {mc_obj.session_id}");
                    }
                } except Exception as e {
                    self.logger.error(f"Error autoclosing media collection: {e}: \n{traceback.format_exc()}\n");
                }
            }
        }
    }

    def delete_media_collections(session_id:str) -> bool {
        # Deletes all closed media collections for the session.
        collection = self.get_collection();

        results = node_get({
            "name": "MediaCollection",
            "archetype.collection_id": collection.id,
            "archetype.session_id": session_id,
            "archetype.status": "CLOSED"
        });

        # Normalize to list
        media_collections = [];
        if isinstance(results, list) {
            media_collections = results;
        } elif results {  # Single object
            media_collections = [results];
        }

        # Delete collections
        for media_collection in media_collections {
            result = media_collection.delete();
            self.logger.warning(f"purged collection {result}");
        }

        return bool(media_collections);  # True if any were deleted
    }

    def send_outbox_message(session_id:str, message:InteractionMessage) -> dict {
        # sends an wppconnect message to a specified session_id via the action
        return self.send_message(session_id=session_id, message=message);
    }

}

