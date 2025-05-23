import:py os;
import:py uuid;
import:py logging;
import:py traceback;
import:py base64;
import:py random;
import:py from datetime { datetime }
import:py from typing { Union }
import:py from logging { Logger }
import:py from jivas.agent.modules.agentlib.utils { Utils }
import:py from .modules.wppconnect_api { WPPConnectAPI }
import:py from jvserve.lib.agent_interface { AgentInterface }
import:jac from jivas.agent.action.action { Action }
import:jac from jivas.agent.memory.interaction_response {
    MessageType, InteractionMessage, TextInteractionMessage, MediaInteractionMessage, MultiInteractionMessage
}

node WPPConnectAction :Action: {
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
    has outbox_min_send_interval:float = 1.0; # the minumum interval (delay) in seconds between sending messages from the outbox
    has outbox_max_send_interval:float = 10.0; # the maximum interval (delay) in seconds between sending messages from the outbox
    has outbox_min_batch_size:int = 1; # the minimum batch size of messages to send from the outbox
    has outbox_max_batch_size:int = 10; # the maximum batch size of messages to send from the outbox
    has outbox:dict = {}; # outbox for outgoing mass messages


    can on_enable() {
        self.on_register();
        self.start_outbox_scheduler();
    }

    can on_disable() {
        self.stop_outbox_scheduler();
    }

    can on_register {

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

    can post_register() {
        # post register procedure to start the outbox scheduler
        self.start_outbox_scheduler();
    }

    can pulse() {
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

    can healthcheck() -> Union[bool, dict] {
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

    can api() -> WPPConnectAPI {
        # load the api instance

        return WPPConnectAPI(
            api_url=self.api_url,
            session=self.session,
            token=self.token,
            secret_key=self.secret_key,
            timeout=self.request_timeout
        );

    }

    can register_session() -> dict {
        # setup procedure for webhook registration on api

        result = {};

        agent_id = self.get_agent().id;
        module_root = self.get_module_root();
        # generate webhook key
        webhook_key = AgentInterface.encrypt_webhook_key(agent_id=agent_id, module_root=module_root, walker="wppconnect_interact");

        if(self.base_url and self.api_url and webhook_key) {
            # complete the full webhook url
            self.webhook_url = f'{self.base_url}/webhook/{webhook_key}';
            self.logger.debug(f'wppconnect webhook url: {self.webhook_url}');

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

        } else {
            self.logger.error('unable to generate webhook url for WPPConnect, missing required parameters');
        }

        return result;
    }

    can logout_session() {
        self.api().logout_session();
        return True;
    }

    can sanitize_message(message:str) {
        return message.replace("**", "*").replace("<br/>", "\n").replace("<b>", "*").replace("</b>", "*");
    }

    can send_message(session_id:str, message:InteractionMessage, is_group:bool = False, parent_message_id:str = "") -> dict {
        # processes an agent response payload format and sends an wppconnect message to a specified session_id via the action
        result = {};

        if(message and session_id) {

            if(not parent_message_id) {
                parent_message_id = message.get_meta('parent_message_id');
            }

            if (message.get_type() == MessageType.SILENCE.value) {}
            elif(message.get_type() == MessageType.TEXT.value) {
                content = self.sanitize_message(message = message.get_content());
                outgoing = Utils.chunk_long_message(message=content, max_length = self.chunk_length, chunk_length = self.chunk_length);

                for chunk in outgoing {
                    result = self.api().send_message(phone=session_id, message=chunk, is_group=is_group, message_id=parent_message_id);
                }


            } elif(message.get_type() == MessageType.MEDIA.value) {
                file_type = WPPConnectAPI.get_file_type(mime_type=message.mime);
                content = self.sanitize_message(message = message.get_content());
                if(file_type.get('file_type') in ["document", "video", "unknown"]) {
                    result = self.api().send_file(phone= session_id, file_url=message.data.get('url'), filename=message.data.get('file_name'), caption = content);
                } elif(file_type.get('file_type') == "image") {
                    result = self.api().send_image(phone=session_id, file_url= message.data.get('url'), filename=message.data.get('file_name'), caption = content);
                }
            } elif(message.get_type() == MessageType.MULTI.value) {
                for message_item in message.get_content_items() {
                    if(message_item.get_type() == MessageType.TEXT.value) {
                        content = self.sanitize_message(message = message_item.get_content());
                        outgoing = Utils.chunk_long_message(message=content, max_length = self.chunk_length, chunk_length = self.chunk_length);
                        for chunk in outgoing {
                            result = self.api().send_message(phone=session_id, message=chunk, is_group=is_group, message_id=parent_message_id);
                        }
                    } elif(message_item.get_type() == MessageType.MEDIA.value) {
                        file_type = WPPConnectAPI.get_file_type(mime_type=message_item.mime);
                        content = self.sanitize_message(message = message_item.get_content());
                        if(file_type.get('file_type') in ["document", "video", "unknown"]) {
                            result = self.api().send_file(phone= session_id, file_url=message_item.data.get('url'), filename=message_item.data.get('file_name'), caption = content);
                        } elif(file_type.get('file_type') == "image") {
                            result = self.api().send_image(phone=session_id, file_url= message_item.data.get('url'), filename=message_item.data.get('file_name'), caption = content);
                        }
                    }
                }
            }
        }

        return result;
    }

    can prepare_interaction_message(message:dict) -> InteractionMessage {
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

    can broadcast_message(message:InteractionMessage, ignore_list:list = []) -> str {
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
                            self.add_outbox_item(job_id=job_id, session_id=frame_node.session_id, message=message);
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

    can restart_scheduler() {
        # Gracefully update scheduler with new parameters
        self.stop_outbox_scheduler();
        self.start_outbox_scheduler();
        self.logger.debug(f"Outbox scheduler restarted with interval {self.outbox_send_interval}s");
    }

    can has_outbox_items() -> bool {
        # check if there are any items in the outbox
        if self.outbox and len(self.outbox) > 0 {
            for (job_id, job) in self.outbox.items() {
                if len(job['pending']) > 0 {
                    return True;
                }
            }
        }
        return False;
    }

    can start_outbox_scheduler() {

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

    can stop_outbox_scheduler() {
        # stop the outbox scheduler

        if(pulse_action := self.get_agent().get_action(action_label="PulseAction")) {
            # remove the outbox scheduler from the pulse action
            pulse_action.remove_schedule(self.get_type());
            self.logger.info(f"Outbox scheduler stopped");
        }
    }

    can send_from_outbox(batch_size: int = 1) -> (int, int, int) {
        # Enhanced batch processing with success tracking
        if not self.has_outbox_items() {
            return (0, 0, 0);
        }

        processed_count = 0;
        success_count = 0;
        failure_count = 0;
        jobs = list(self.outbox.items());

        while processed_count < batch_size and len(jobs) > 0 {
            (job_id, job) = jobs.pop(0);

            if not job['pending'] {
                continue;
            }

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
                        self.update_interaction_context(item, interaction_message);
                    } else {
                        job['failed'][item_id] = item;
                        failure_count += 1;
                    }

                    del job['pending'][item_id];
                    processed_count += 1;
                } except Exception as e {
                    self.logger.error(f"Outbox message processing failed: {str(e)}");
                    job['failed'][item_id] = item;
                    del job['pending'][item_id];
                    failure_count += 1;
                    processed_count += 1;
                }
            }

            # Update job state
            self.outbox[job_id] = job;
            self.maybe_trigger_callback(job_id, job);
        }

        return (processed_count, success_count, failure_count);
    }

    can update_interaction_context(item:dict, message:InteractionMessage) {
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

    can add_outbox_job(messages: list, callback_url: str = "") -> str {
        # Adds a batch of messages to the outbox with comprehensive validation
        # Returns job ID if successful, empty string if no valid messages

        if not messages or not isinstance(messages, list) {
            self.logger.error("Invalid messages format - expected list of message dicts");
            return "";
        }

        job_id = str(uuid.uuid4());
        valid_items = 0;
        validation_errors = [];

        # Initialize job structure before processing messages
        self.outbox[job_id] = self.create_job_structure(callback_url);

        for (index, item) in enumerate(messages) {
            if not self.validate_message_item(item, index, validation_errors) {
                continue;
            }

            try {
                interaction_message = self.prepare_interaction_message(
                    message=item['message']
                );
                self.add_outbox_item(
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
            del self.outbox[job_id];
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

    can validate_message_item(item: dict, index: int, error_log: list) -> bool {
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

    can validate_text_message(message: dict, index: int) -> bool {
        if not message.get('content') {
            self.logger.error(f"Item {index}: TEXT message missing content");
            return False;
        }
        return True;
    }

    can validate_media_message(message: dict, index: int) -> bool {
        required = {'mime', 'content', 'data'};
        missing = required - message.keys();

        if missing {
            self.logger.error(f"Item {index}: MEDIA message missing {missing}");
            return False;
        }

        if 'url' not in message['data'] {
            self.logger.error(f"Item {index}: MEDIA message missing URL");
            return False;
        }
        return True;
    }

    can validate_multi_message(message: dict, index: int) -> bool {
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

    can create_job_structure(callback_url: str = "") -> dict {
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

    can add_outbox_item(job_id: str, session_id: str, message: InteractionMessage) {
        # Adds validated item to specified job with type checking

        if not all([
            isinstance(job_id, str),
            isinstance(session_id, str),
            isinstance(message, InteractionMessage)
        ]) {
            self.logger.error("Invalid parameters for outbox item");
            return;
        }

        if job_id not in self.outbox {
            self.logger.warning(f"Creating new job {job_id}...");
            self.outbox[job_id] = self.create_job_structure();
        }

        item_id = str(uuid.uuid4());
        self.outbox[job_id]['pending'][item_id] = {
            'session_id': session_id,
            'message': message.export(),
            'added_at': datetime.now().isoformat()
        };

        # Update job statistics
        self.outbox[job_id]['stats']['total'] += 1;
    }

    can maybe_trigger_callback(job_id:str, job:dict) {
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

    can clamp(value:Union[int,float], min_val:Union[int,float], max_val:Union[int,float]) -> Union[int,float] {
        # Utility function for boundary constraints
        return max(min_val, min(value, max_val));
    }

    can calculate_dynamic_batch_size() -> int {
        # Calculate batch size based on success rate and current interval
        base_size = max(1, int(self.outbox_base_rate_per_minute * (self.outbox_send_interval / 60)));

        # Add jitter to prevent patterns
        jittered_size = base_size * random.uniform(0.8, 1.2);

        # Apply min/max constraints
        return self.clamp(int(jittered_size), self.outbox_min_batch_size, self.outbox_max_batch_size);
    }

    can update_send_parameters(successes: int, failures: int) {
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

}
