import os;
import uuid;
import shutil;
import logging;
import traceback;
import base64;
import random;
import from datetime { datetime, timezone }
import from typing { Union }
import from logging { Logger }
import from .modules.wppconnect_api { WPPConnectAPI }
import from actions.jivas.wppconnect_action.outbox { Outbox }
import from actions.jivas.wppconnect_action.outbox_item { OutboxItem }
import from actions.jivas.wppconnect_action.job { Job }
import from actions.jivas.wppconnect_action.outbox_item_status { OutboxItemStatus }

import from jivas.agent.modules.text.chunking { chunk_long_message }

import from jivas.agent.memory.collection { Collection }
import from jivas.agent.action.action { Action }
import from jivas.agent.memory.interaction_response {
    MessageType, InteractionMessage, TextInteractionMessage, MediaInteractionMessage, MultiInteractionMessage
}
import from jac_cloud.plugin.jaseci { JacPlugin as Jac }
import from jivas.agent.core.graph_node { GraphNode }
import from .wppconnect_interact { wppconnect_interact }


node WPPConnectAction(Action) {
    # houses configurations per agent for whatsapp api communications provided by wppconnect api

    # set up logger
    static has logger:Logger = logging.getLogger(__name__);

    has api_url:str = ""; # WPPConnect Server URL
    has secret_key:str = ""; # WPPConnect Server Secret Key
    has token:str = ""; # WPPConnect Server API Key for this session
    has session:str = ""; # WPPConnect Server Instance ID
    has base_url:str = ""; # Jivas Base URL
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
    # outbox settings
    has outbox_base_rate_per_minute:int = 20;  # WhatsApp API rate limit for sending messages
    has outbox_send_interval:float = 1.0; # the interval (delay) in seconds between sending messages from the outbox
    has outbox_min_send_interval:float = 1.0; # the minimum interval (delay) in seconds between sending messages from the outbox
    has outbox_max_send_interval:float = 10.0; # the maximum interval (delay) in seconds between sending messages from the outbox
    has outbox_min_batch_size:int = 1; # the minimum batch size of messages to send from the outbox
    has outbox_max_batch_size:int = 10; # the maximum batch size of messages to send from the outbox
    # poll settings
    has poll_manager_action:str = "PollManagerInteractAction"; # the label of the poll manager action to use for polls
    has recent_files_time_window:int = 30; # the time window in seconds to search for recent files


    def on_enable() {
        self.on_register();
        self.start_outbox_scheduler();
    }

    def on_disable() {
        self.stop_outbox_scheduler();
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

        self.register_session();
    }

    def post_register() {
        # post register procedure to start the outbox scheduler
        self.start_outbox_scheduler();
    }

    def pulse() {
        # Main scheduling pulse with adaptive rate control
        if not self.has_outbox_items() {
            self.stop_outbox_scheduler();
            return;
        }

        # Check system health with exponential backoff
        if (health_status := self.healthcheck()) != True {
            self.logger.warning(f"Outbox scheduler backing off due to healthcheck failure.");
            return;
        }

        # Calculate dynamic batch size based on current rate window
        batch_size = self.calculate_dynamic_batch_size();

        # Process messages with current batch size
        (processed, successes, failures) = self.send_from_outbox(batch_size=batch_size);

        # Update rate limiting parameters
        self.update_send_parameters(successes, failures);

        # Restart scheduler with new parameters if items remain
        if self.has_outbox_items() {
            self.restart_scheduler();
        }
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

    def register_session() -> dict {
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
            self.logger.debug(f'wppconnect webhook url: {callback_url}');

        }

        result = self.api().register_session(webhook_url = self.webhook_url, wait_qr_code = True);

        if result is not None and result.get('status') != 'ERROR' {
            # check if the response contains a valid token
            if result.get('token') {
                self.token = result.get('token');
                # remove the token from the payload now that we've saved it
                del result['token'];
            }

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

    def prepare_interaction_message(message:dict) -> InteractionMessage {
        # prepare the interaction message based on the message type
        if not message {
            return None;
        }

        message_type = message.get('message_type');

        if message_type == MessageType.TEXT.value {
            interaction_message = TextInteractionMessage();
            interaction_message.load(message);
        } elif message_type == MessageType.MEDIA.value {
            interaction_message = MediaInteractionMessage();
            interaction_message.load(message);
        } elif message_type == MessageType.MULTI.value {
            interaction_message = MultiInteractionMessage();
            interaction_message.load(message);
        } else {
            return None;
        }

        return interaction_message;
    }

    def broadcast_message(message:InteractionMessage, ignore_list:list = []) -> str {
        # processes an agent response payload format and sends a message to all session_ids via the action

        agent_node = self.get_agent();
        job_id = str(uuid.uuid4());

        if(frames := agent_node.get_memory().get_frames() ) {
            # get all frames then proceed to broadcast
            for frame_node in frames {
                if(frame_node.session_id not in ignore_list) {
                    if(interaction_node := frame_node.get_last_interaction()) {
                        if interaction_node.channel in ['whatsapp'] {
                            # add the message to the outbox
                            self.add_outbox_item(status=OutboxItemStatus.PENDING, job_id=job_id, session_id=frame_node.session_id, message=message);
                        }
                    }
                }
            }

            # start the outbox scheduler
            self.start_outbox_scheduler();
            return job_id;
        }

        return None;
    }

    # --------------- OUTBOX SCHEDULER ----------------

    def restart_scheduler() {
        # Gracefully update scheduler with new parameters
        self.stop_outbox_scheduler();
        self.start_outbox_scheduler();
        self.logger.debug(f"Outbox scheduler restarted with interval {self.outbox_send_interval}s");
    }

    def has_outbox_items() -> bool {
        jobs = self.get_jobs();
        if jobs and len(jobs) > 0 {
            for (job_id, job) in jobs.items() {
                if len(job['pending']) > 0 {
                    return True;
                }
            }
        }
        return False;
    }

    def start_outbox_scheduler() {

        # Proceed with scheduler start
        if self.has_outbox_items() {
            if pulse_action := self.get_agent().get_action(action_label="PulseAction") {
                pulse_action.add_schedule(
                    self.get_type(),
                    f'every({self.outbox_send_interval}).seconds'
                );
                self.logger.info(
                    f"Outbox scheduler started: {self.outbox_send_interval}s interval "
                    f"(Batch size: {self.outbox_max_batch_size})"
                );
            }
        }
    }

    def stop_outbox_scheduler() {
        # stop the outbox scheduler

        if(pulse_action := self.get_agent().get_action(action_label="PulseAction")) {
            # remove the outbox scheduler from the pulse action
            pulse_action.remove_schedule(self.get_type());
            self.logger.info(f"Outbox scheduler stopped");
        }
    }

    def send_from_outbox(batch_size: int = 1) -> (int, int, int) {
        # Enhanced batch processing with success tracking
        if not self.has_outbox_items() {
            return (0, 0, 0);
        }

        processed_count = 0;
        success_count = 0;
        failure_count = 0;
        jobs = list(self.get_jobs().items());

        while processed_count < batch_size and len(jobs) > 0 {
            (job_id, job) = jobs.pop(0);

            # Process batch slice
            processable = min(batch_size - processed_count, len(job['pending']));
            items = list(job['pending'].items())[:processable];

            for (item_id, item) in items {
                try {
                    interaction_message = self.prepare_interaction_message(
                        message=item['message']
                    );
                    result = self.send_message(
                        session_id=item['session_id'],
                        message=interaction_message
                    );

                    if result.get('status') == 'success' {
                        job['processed'][item_id] = item;
                        success_count += 1;
                        new_success_rate = job['success_rate'] + success_count;
                        self.update_job_collection(status=OutboxItemStatus.PROCESSED, item_id=item_id, job_id=job_id, success_rate=new_success_rate);

                        self.update_interaction_context(item, interaction_message);
                    } else {
                        job['failed'][item_id] = item;
                        failure_count += 1;
                        self.update_job_collection(status=OutboxItemStatus.FAILED, item_id=item_id, job_id=job_id);
                    }

                    del job['pending'][item_id];
                    processed_count += 1;
                } except Exception as e {
                    self.logger.error(f"Outbox message processing failed: {str(e)}");
                    self.update_job_collection(status=OutboxItemStatus.FAILED, item_id=item_id, job_id=job_id);
                    job['failed'][item_id] = item;
                    del job['pending'][item_id];
                    failure_count += 1;
                    processed_count += 1;
                }
            }

            # Update job state
            self.maybe_trigger_callback(job_id, job);
        }

        return (processed_count, success_count, failure_count);
    }

    def update_interaction_context(item:dict, message:InteractionMessage) {
        # Shared context update logic
        agent_node = self.get_agent();
        frame_node = agent_node.get_memory().get_frame(
            agent_id=agent_node.id,
            session_id=item['session_id'],
            force_session=True
        );
        frame_node.add_unprompted_interaction(
            message=message.get_content(),
            channel="whatsapp"
        );
    }

    def add_outbox_job(messages: list, callback_url: str = "", status: OutboxItemStatus = OutboxItemStatus.PENDING) -> str {
        # Adds a batch of messages to the outbox with comprehensive validation
        # Returns job ID if successful, empty string if no valid messages
        self.logger.warning("adding add_outbox_job");

        if not messages or not isinstance(messages, list) {
            self.logger.error("Invalid messages format - expected list of message dicts");
            return "";
        }

        job_id = str(uuid.uuid4());
        valid_items = 0;
        validation_errors = [];


        for (index, item) in enumerate(messages) {
            if not self.validate_message_item(item, index, validation_errors) {
                continue;
            }

            try {
                interaction_message = self.prepare_interaction_message(
                    message=item['message']
                );
                self.add_outbox_item(
                    status=OutboxItemStatus.PENDING,
                    job_id=job_id,
                    session_id=item['to'],
                    message=interaction_message
                );
                valid_items += 1;
            } except Exception as e {
                error_msg = f"Message {index} processing failed: {str(e)}";
                validation_errors.append(error_msg);
                self.logger.error(error_msg);
            }
        }

        # Clean up empty jobs
        if valid_items == 0 {
            self.purge_outbox(job_id=job_id);
            self.logger.warning(f"Job {job_id} contained no valid messages");
            if validation_errors {
                self.logger.debug(f"Validation errors:\n" + "\n".join(validation_errors));
            }
            return "";
        }

        # Start scheduler only if valid messages exist
        self.start_outbox_scheduler();
        return job_id;
    }

    def validate_message_item(item: dict, index: int, error_log: list) -> bool {
        # Validates individual message items with detailed error reporting
        required_keys = {'to', 'message'};
        message_types = {'TEXT', 'MEDIA', 'MULTI'};

        if not isinstance(item, dict) {
            error_log.append(f"Item {index}: Not a dictionary");
            return False;
        }

        missing_keys = required_keys - item.keys();
        if missing_keys {
            error_log.append(f"Item {index}: Missing keys {missing_keys}");
            return False;
        }

        message = item.get('message', {});
        msg_type = message.get('message_type', '').upper();

        if msg_type not in message_types {
            error_log.append(f"Item {index}: Invalid message type '{msg_type}'");
            return False;
        }

        # Type-specific validation
        validation_map = {
            'TEXT': self.validate_text_message,
            'MEDIA': self.validate_media_message,
            'MULTI': self.validate_multi_message
        };

        if not validation_map[msg_type](message, index) {
            return False;
        }

        return True;
    }

    def validate_text_message(message: dict, index: int) -> bool {
        if not message.get('content') {
            self.logger.error(f"Item {index}: TEXT message missing content");
            return False;
        }
        return True;
    }

    def validate_media_message(message: dict, index: int) -> bool {
        required = {'mime', 'content', 'data'};
        file_type = WPPConnectAPI.get_file_type(mime_type=message.get('mime', 'unknown'));

        if(file_type.get('file_type') == "poll") {
            required.remove('content');
        }

        missing = required - message.keys();

        if missing {
            self.logger.error(f"Item {index}: MEDIA message missing {missing}");
            return False;
        }

        if (file_type.get('file_type') == "poll" and all([key in message.get('data', {}) for key in ['name', 'choices', 'options']])) {
            return True;
        }

        if 'url' not in message['data'] {
            self.logger.error(f"Item {index}: MEDIA message missing URL");
            return False;
        }
        return True;
    }

    def validate_multi_message(message: dict, index: int) -> bool {
        components = message.get('content', []);

        if not isinstance(components, list) or len(components) < 2 {
            self.logger.error(f"Item {index}: MULTI message requires 2+ components");
            return False;
        }

        for (i, comp) in enumerate(components) {
            if not comp.get('message_type') {
                self.logger.error(f"Item {index}: Component {i} missing message_type");
                return False;
            }
        }
        return True;
    }

    def create_job_structure(callback_url: str = "") -> dict {
        # Returns standardized job structure with metadata
        return {
            'pending': {},
            'processed': {},
            'failed': {},
            'callback_url': callback_url,
            'created_at': datetime.now().isoformat(),
            'stats': {
                'total': 0,
                'success_rate': 0.0
            }
        };
    }

    def add_outbox_item(job_id: str, session_id: str, status: OutboxItemStatus = OutboxItemStatus.PENDING, message: InteractionMessage) {
        # Adds validated item to specified job with type checking

        if not all([
            isinstance(job_id, str),
            isinstance(session_id, str),
            isinstance(message, InteractionMessage)
        ]) {
            self.logger.error("Invalid parameters for outbox item");
            return;
        }

        item_id = str(uuid.uuid4());
        self.add_outbox_item_collection(status=status, job_id= job_id, item_id=item_id, session_id=session_id, message=message);
    }

    def maybe_trigger_callback(job_id:str, job:dict) {
        # Unified callback handler
        if not job['pending'] and job.get('callback_url') {
            status = 'success' if not job['failed'] else 'partial';
            self.api().send_rest_request(
                endpoint=job['callback_url'],
                method='POST',
                data={
                    'status': status,
                    'job_id': job_id,
                    'success_count': len(job['processed']),
                    'failure_count': len(job['failed']),
                    'pending_count': len(job['pending']),
                    'timestamp': datetime.now().isoformat()
                },
                json_body=True,
                use_full_url=True
            );
        }
    }

    def clamp(value:Union[int,float], min_val:Union[int,float], max_val:Union[int,float]) -> Union[int,float] {
        # Utility function for boundary constraints
        return max(min_val, min(value, max_val));
    }

    def calculate_dynamic_batch_size() -> int {
        # Calculate batch size based on success rate and current interval
        base_size = max(1, int(self.outbox_base_rate_per_minute * (self.outbox_send_interval / 60)));

        # Add jitter to prevent patterns
        jittered_size = base_size * random.uniform(0.8, 1.2);

        # Apply min/max constraints
        return self.clamp(int(jittered_size), self.outbox_min_batch_size, self.outbox_max_batch_size);
    }

    def update_send_parameters(successes: int, failures: int) {
        # Adaptive rate control algorithm
        total = successes + failures;
        success_rate = successes / total if total > 0 else 1.0;

        # Calculate interval adjustment
        if success_rate < 0.7 {
            # Degraded performance - slow down
            adjustment_factor = 1 + (0.7 - success_rate);
            self.outbox_send_interval *= adjustment_factor;
        } else {
            # Good performance - speed up cautiously
            adjustment_factor = 1 - (success_rate - 0.7) * 0.3;
            self.outbox_send_interval *= adjustment_factor;
        }

        # Apply jitter and constraints
        self.outbox_send_interval *= float(random.uniform(0.9, 1.1));
        self.outbox_send_interval = self.clamp(
            self.outbox_send_interval,
            self.outbox_min_send_interval,
            self.outbox_max_send_interval
        );
    }


    # collection
    def add_outbox_item_collection(status:OutboxItemStatus, job_id: str, item_id: str, session_id: str, message: InteractionMessage) -> Job {
        collection = self.get_collection();
        outbox_item = (collection spawn _add_job_collection(status=status, job_id=job_id, item_id=item_id, session_id=session_id, message=message)).outbox_item;
        if outbox_item {
            self.increment_job_count();
        }
        return outbox_item;
    }

    def purge_outbox(job_id: str="") -> Job {
        collection = self.get_collection();
        jobs = (collection spawn _delete_job(job_id=job_id)).deleted;
        total_jobs = self.get_job_count();
        self.set_job_count(total_jobs - len(jobs));
        return jobs;
    }

    def get_jobs(job_id:str = "") -> dict {
        collection = self.get_collection();
        return (collection spawn _get_jobs(job_id=job_id)).outbox_item;
    }

    def update_job_collection(status: str="", job_id:str = "", item_id:str = "", success_rate:float = 0.0) -> Job {
        collection = self.get_collection();
        return (collection spawn _update_job_collection(status=status, job_id=job_id, item_id=item_id, success_rate=success_rate));
    }

    def import_outbox(outbox: dict, purge_collection: bool = False) -> bool {
        try {
            collection = self.get_collection();

            # purge jobs collection
            if(purge_collection){
                self.purge_outbox();
            }

            # import outbox
            for (job_id, job_data) in outbox.items() {
                for (item_id, job) in job_data['pending'].items() {
                    self.add_outbox_item_collection(status=OutboxItemStatus.PENDING, job_id=job_id, item_id=item_id, session_id=job['session_id'], message=job['message']);
                }
                for (item_id, job) in job_data['processed'].items() {
                    self.add_outbox_item_collection(status=OutboxItemStatus.PROCESSED, job_id=job_id, item_id=item_id, session_id=job['session_id'], message=job['message']);
                }
                for (item_id, job) in job_data['failed'].items() {
                    self.add_outbox_item_collection(status=OutboxItemStatus.FAILED, job_id=job_id, item_id=item_id, session_id=job['session_id'], message=job['message']);
                }
            }

            # Calculate dynamic batch size based on current rate window
            batch_size = self.calculate_dynamic_batch_size();

            # Process messages with current batch size
            (processed, successes, failures) = self.send_from_outbox(batch_size=batch_size);

            # Update rate limiting parameters
            self.update_send_parameters(successes, failures);

            # Restart scheduler with new parameters if items remain
            if self.has_outbox_items() {
                self.restart_scheduler();
            }

            return True;
        } except Exception as e {
            self.logger.error(f"Error importing outbox: {e}");
            return False;
        }
    }


    def get_job_count() -> int {
        collection = self.get_collection();
        return collection.data_get('job_count') or 0;
    }

    def set_job_count(amount:int) {
        collection = self.get_collection();
        collection.data_set('job_count', amount);
    }

    def increment_job_count(amount:int=1) -> int {
        # Increment the job_count by the specified amount (default 1).
        collection = self.get_collection();
        if amount < 0 {
            return self.get_job_count();
        }

        job_count = self.get_job_count() + 1;
        collection.data_set('job_count', job_count);

        return job_count;
    }

    def list_outbox_items(page:int, limit:int, filtered_status:list = [], filtered_job_id:list = []) -> dict {
        # Lists all document entries in the manifest with pagination.

        collection = self.get_collection();
        result = collection spawn _list_outbox_items(page=page, limit=limit, total_items=self.get_job_count(), filtered_status=filtered_status, filtered_job_id=filtered_job_id);
        if not result {
            self.logger.error("No jobs found in the manifest.");
            return {};
        }
        return {
            "page": result.page,
            "limit": result.limit,
            "total_items": result.total_items,
            "total_pages": result.total_pages,
            "has_previous": result.has_previous,
            "has_next": result.has_next,
            "items": result.items,
            "jobs": result.jobs
        };
    }


    def get_wppconnect_media(session_id:str) -> list {
        collection = self.get_collection();
        media_list = self.api().list_files_in_folder(f".files/{self.get_agent().id}/{self.label}/media/{session_id}");

        media_urls = [];
        for output_filename in media_list {
            output_file_path = f"media/{session_id}/{output_filename}";
            file_url = self.get_file_url(output_file_path);
            media_urls.append(file_url);
        }
        return media_urls;
    }

    def get_wppconnect_recent_files(session_id:str, seconds:int=0) -> list {
        return self.api().list_files_in_folder(directory=f".files/{self.get_agent().id}/{self.label}/media/{session_id}", within_seconds=seconds);
    }

    def delete_wppconnect_media(session_id:str) {
        media_path = f".files/{self.get_agent().id}/{self.label}/media/{session_id}";
        shutil.rmtree(media_path, ignore_errors=True);
    }
}


walker _delete_job {
    has job_id:str = "";
    has deleted:list = [];
    has job_deleted:list = [];

    obj __specs__ {
        static has private:bool = True;
    }

    can on_collection with Collection entry {
        visit [-->](`?Outbox);
    }

    can on_outbox with Outbox entry {
        if not self.job_id {
            self.job_deleted.append(here);
            visit [-->](`?Job);
        } else {
            visit [-->](`?Job)(?job_id == self.job_id);
        }
    }

    can on_job with Job entry {
        visit [-->](`?OutboxItem);

        if len([-->]) <= 1 or not self.job_id {
            self.job_deleted.append(here);
        }
    }

    can on_outbox_item with OutboxItem entry {
        self.deleted.append(here);
    }

    can on_exit with exit {
        for item in self.deleted {
            Jac.destroy(item);
        }

        for item in self.job_deleted {
            Jac.destroy(item);
        }
    }

}

walker _add_job_collection {
    has outbox_item:OutboxItem = None;
    has job_id:str = "";
    has item_id:str = "";
    has session_id:str = "";
    has status:OutboxItemStatus = OutboxItemStatus.PENDING;
    has message:InteractionMessage = None;


    obj __specs__ {
        static has private:bool = True;
    }

    can on_collection with Collection entry {
        visit [-->](`?Outbox) else {
            outbox = Outbox();
            here ++> outbox;
            visit [-->](`?Outbox);
        }
    }

    can on_outbox with Outbox entry {
        visit [-->](`?Job)(?job_id == self.job_id) else {
            job = Job(job_id=self.job_id);
            here ++> job;

            visit [-->](`?Job)(?job_id == self.job_id);
        }
    }

    can on_job with Job entry {
        visit [-->](`?OutboxItem)(?item_id == self.item_id) else {
            date_now = datetime.now().isoformat();
            self.outbox_item = OutboxItem(item_id=self.item_id, session_id=self.session_id, added_at=date_now, message=self.message, status=self.status);
            here ++> self.outbox_item;
            here.total = here.total + 1;
            here.created_at = date_now;
        }
    }
}

walker _update_job_collection {
    has status:str = "";
    has item_id:str = "";
    has job_id:str = "";
    has success_rate:float = 0.0;

    obj __specs__ {
        static has private:bool = True;
    }

    can on_collection with Collection entry {
        visit [-->](`?Outbox);
    }

    can on_outbox with Outbox entry {
        visit [-->](`?Job)(?job_id == self.job_id);
    }

    can on_job with Job entry {
        if here.job_id == self.job_id {
            if self.success_rate {
                here.success_rate = self.success_rate / here.total;
            }
        }

        if self.status in OutboxItemStatus {
            visit [-->](`?OutboxItem)(?item_id == self.item_id);
        }
    }

    can on_outbox_item with OutboxItem entry {
        here.status = self.status;
    }
}

walker _get_jobs {
    has job_id:str = "";
    has outbox_item:dict = {};

    obj __specs__ {
        static has private:bool = True;
    }

    can on_collection with Collection entry {
        visit [-->](`?Outbox);
    }

    can on_outbox with Outbox entry {
        if self.job_id {
            visit [-->](`?Job)(?job_id == self.job_id);
        } else {
            visit [-->](`?Job);
        }
    }

    can on_job with Job entry {

        # get pending post
        pending_outbox_item_node = [-->](`?OutboxItem)(?status == OutboxItemStatus.PENDING);
        pending_outbox_item_data = {};
        for item in pending_outbox_item_node {
            pending_outbox_item_data[item.item_id] = {
                "session_id": item.session_id,
                "message": item.message,
                "added_at": item.added_at
            };
        }

        # get processed outbox item
        processed_outbox_item_node = [-->](`?OutboxItem)(?status == OutboxItemStatus.PROCESSED);
        processed_outbox_item_data = {};
        for item in processed_outbox_item_node {
            processed_outbox_item_data[item.item_id] = {
                "session_id": item.session_id,
                "message": item.message,
                "added_at": item.added_at
            };
        }

        # get failed outbox item
        failed_outbox_item_node = [-->](`?OutboxItem)(?status == OutboxItemStatus.FAILED);
        failed_outbox_item_data = {};
        for item in failed_outbox_item_node {
            failed_outbox_item_data[item.item_id] = {
                "session_id": item.session_id,
                "message": item.message,
                "added_at": item.added_at
            };
        }

        self.outbox_item[here.job_id] = {
            "pending": pending_outbox_item_data,
            "processed": processed_outbox_item_data,
            "failed": failed_outbox_item_data,
            "success_rate": here.success_rate,
            "total": here.total
        };

    }
}


walker _list_outbox_items {
    # Spawns on action collection and returns a paginated, flattened list of doc entries with total count and page control

    has page:int = 1;
    has limit:int = 50;
    has offset:int = 0;
    has total_items:int = 0;
    has total_pages:int = 1;
    has has_previous:bool = False;
    has has_next:bool = False;
    has current_index:int = 0;
    has items:list = [];
    has filtered_status:str = [];
    has filtered_job_id:str = [];
    has jobs:list = [];

    # set up logger
    static has logger:Logger = logging.getLogger(__name__);

    obj __specs__ {
        static has private: bool = True;
    }

    can on_collection with Collection entry {
        visit [-->](`?Outbox);
    }

    can on_outbox with Outbox entry {
        # First, count total doc entries
        job_entries = [-->](`?Job);

        # Calculate offset based on page and limit
        if self.limit > 0 {
            self.offset = (self.page - 1) * self.limit;
            self.total_pages = (self.total_items // self.limit) + (1 if self.total_items % self.limit > 0 else 0);
            self.has_previous = self.page > 1;
            self.has_next = self.page < self.total_pages;
        } else {
            self.offset = 0;
            self.total_pages = 1;
            self.has_previous = False;
            self.has_next = False;
        }

        visit [-->](`?Job);
    }

    can on_job with Job entry {
        self.jobs.append(here.job_id);
        if self.filtered_job_id {
            if(here.job_id in self.filtered_job_id) {
                visit [-->](`?OutboxItem);
            }
        } else {
            visit [-->](`?OutboxItem);
        }
    }

    can on_outbox_item with OutboxItem entry {
        if self.filtered_status {
            if here.status.name in self.filtered_status {
                if self.current_index >= self.offset and (self.limit == 0 or len(self.items) < self.limit) {
                    outbox_item = here.export();
                    job_id = [<--](`?Job)[0].job_id;
                    outbox_item['job_id'] = job_id;
                    self.items.append(outbox_item);
                }
                self.current_index += 1;
                if self.limit != 0 and len(self.items) >= self.limit {
                    disengage;
                }
            }
        }else {
            if self.current_index >= self.offset and (self.limit == 0 or len(self.items) < self.limit) {
                outbox_item = here.export();
                job_id = [<--](`?Job)[0].job_id;
                outbox_item['job_id'] = job_id;
                self.items.append(outbox_item);
            }
            self.current_index += 1;
            if self.limit != 0 and len(self.items) >= self.limit {
                disengage;
            }
        }
    }
}

