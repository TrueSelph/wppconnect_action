import:py os;
import:py uuid;
import:py logging;
import:py traceback;
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
    has webhook_url:str = ""; # JIVAS webhook for WPPConnect
    has request_timeout:float = 10.0; # the length of time this action waits for api to complete request
    has chunk_length:int = 1024; # max length of message to send
    # when set, the wa push name value is used as the user name
    has use_pushname:bool = True; # use the WhatsApp push name as the user name
    has ignore_newsletters:bool = True; # ignore newsletters
    has ignore_forwards:bool = True; # ignore forwarded messages

    has outbox_send_interval:float = 2.0; # the interval (delay) in seconds between sending messages from the outbox
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

        if(not self.has_outbox_items()) {
            self.stop_outbox_scheduler();
            return;
        }

        if((result := self.healthcheck()) != True) {
            return;
        }

        # grab and send the next item in the outbox
        self.send_next_outbox_item();
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

    can start_outbox_scheduler() {
        # start the outbox scheduler
        if(self.has_outbox_items()) {
            # apply configurations to pulse action
            if(pulse_action := self.get_agent().get_action(action_label="PulseAction")) {
                # add the outbox scheduler to the pulse action
                pulse_action.add_schedule(self.get_type(), f'every({self.outbox_send_interval}).seconds');
                self.logger.info(f"wppconnect outbox scheduler running");
            }
        }
    }

    can stop_outbox_scheduler() {
        # stop the outbox scheduler
        if(pulse_action := self.get_agent().get_action(action_label="PulseAction")) {
            # remove the outbox scheduler from the pulse action
            pulse_action.remove_schedule(self.get_type());
            self.logger.info(f"wppconnect outbox scheduler stopped");
        }
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

    can add_outbox_job(messages:list, callback_url:str="") -> str {
        # add a job to the outbox based on a list of message items
        # the structure of the messages is as follows:
        # TEXT
        # [ {
        #     "to": "session_id",
        #     "message": {
        #         "message_type": "TEXT",
        #         "content": "message content"
        #     }
        # } ]
        # MEDIA
        # [ {
        #     "to": "session_id",
        #     "message": {
        #         "message_type": "MEDIA",
        #         "mime": "image/jpeg",
        #         "content": "message content",
        #         "data": {
        #             "url": "https://example.com/image.jpg",
        #             "file_name": "image.jpeg"
        #         }
        #     }
        # } ]
        # MULTI
        # [ {
        #     "to": "session_id",
        #     "message": {
        #         "message_type": "MULTI",
        #         "content": [
        #             {
        #                 "message_type": "TEXT",
        #                 "content": "message content"
        #             },
        #             {
        #                 "message_type": "MEDIA",
        #                 "mime": "image/jpeg",
        #                 "content": "message content",
        #                 "data": {
        #                     "url": "https://example.com/image.jpg",
        #                     "file_name": "image.jpg"
        #                 }
        #             }
        #         ]
        #     }
        # } ]

        # the callback_url is optional and can be used to send a callback to the agent when the job is complete

        if not messages {
            return;
        }

        job_id = str(uuid.uuid4());

        # prepare the list of message items

        for item in messages {

            message = item.get('message');
            session_id = item.get('to');
            message_type = message.get('message_type');
            # check if the item is a valid message
            if not message {
                continue;
            }
            # check if the item has a session id
            if not session_id {
                continue;
            }
            # check if the item has a message type
            if not message_type {
                continue;
            }

            interaction_message = self.prepare_interaction_message(message=message);

            # add the item to the outbox
            self.add_outbox_item(job_id=job_id, session_id=session_id, message=interaction_message);

        }

        if callback_url {
            # add the callback url to the job if supplied
            self.outbox[job_id]['callback_url'] = callback_url;
        }

        # start the scheduler if not already running
        self.start_outbox_scheduler();

        return job_id;
    }

    can add_outbox_item(job_id:str, session_id:str, message:InteractionMessage) {
        # add an item to the outbox under a job id
        if not all([job_id, session_id, message]) {
            return;
        }

        item_id = str(uuid.uuid4());

        if job_id in self.outbox {
            # Add the item to the existing outbox job
            self.outbox[job_id]['pending'][item_id] = {
                'session_id': session_id,
                'status': 'pending',
                'message': message.export(),
            };
        } else {
            # Create a new outbox job structure
            self.outbox[job_id] = {
                'pending': {
                    item_id: {
                        'session_id': session_id,
                        'status': 'pending',
                        'message': message.export(),
                    }
                },
                'processed': {},
                'failed': {}
            };
        }
    }

    can send_next_outbox_item() {
        # send the next item in the outbox
        if not self.has_outbox_items() {
            return;
        }

        do_callback = False;

        for (job_id, job) in self.outbox.items() {

            if len(job['pending']) > 0 {
                # get the first item in the pending list
                item_id = list(job['pending'].keys())[0];
                item = job['pending'][item_id];

                # load the interaction message
                interaction_message = self.prepare_interaction_message(message=item['message']);
                # send the message
                result = self.send_message(session_id=item['session_id'], message=interaction_message);

                if result.get('status') != 'success' {

                    # move the item to failed
                    job['failed'][item_id] = item;
                    del job['pending'][item_id];

                } else {

                    # move the item to processed
                    job['processed'][item_id] = item;

                    # if this is the last item in the pending list,
                    # ensure we call the callback url, if any
                    if len(job['pending']) == 1 and job.get('callback_url') {
                        do_callback = True;
                    }
                    # then, remove the item from the pending list
                    del job['pending'][item_id];

                    # add unprompted interaction to the interaction response for context
                    agent_node = self.get_agent();
                    frame_node = agent_node.get_memory().get_frame(agent_id = agent_node.id, session_id = item['session_id'], force_session=True);
                    frame_node.add_unprompted_interaction(message = interaction_message.get_content(), channel = "whatsapp");
                }

                # update the outbox
                self.outbox[job_id] = job;

                if do_callback {
                    # call the callback url if supplied
                    self.api().send_rest_request(
                        endpoint=job['callback_url'],
                        method='POST',
                        data={
                            'status': 'success' if len(self.outbox[job_id]['failed']) == 0 and len(self.outbox[job_id]['pending']) == 0 and len(self.outbox[job_id]['processed']) > 0 else 'error',
                            'result': self.outbox[job_id]
                        },
                        json_body=True,
                        use_full_url=True
                    );
                }

                break; # exit after processing one item
            }
        }
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

}
