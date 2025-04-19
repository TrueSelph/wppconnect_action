import:py os;
import:py logging;
import:py traceback;
import:py from logging { Logger }
import:py from jivas.agent.modules.agentlib.utils { Utils }
import:py from .modules.wppconnect_api { WPPConnectAPI }
import:py from jvserve.lib.agent_interface { AgentInterface }
import:jac from jivas.agent.action.action { Action }
import:jac from jivas.agent.memory.interaction_response { MessageType }

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
    has chunk_length:int = 1024; # max length of message to send
    # when set, the wa push name value is used as the user name
    has use_pushname:bool = True; # use the WhatsApp push name as the user name
    has ignore_newsletters:bool = True; # ignore newsletters


    can on_enable(){
        registered = self.on_register();
        if(not registered) {
            self.enabled = False;
        }
    }

    can api() -> WPPConnectAPI {
        # load the api instance

        return WPPConnectAPI(
            api_url=self.api_url,
            session=self.session,
            token=self.token,
            secret_key=self.secret_key
        );

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

        if(self.enabled) {
            if(result := self.register_session()) {
                self.enabled = True;
            } else {
                self.enabled = False;
            }
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

    can healthcheck() -> bool {
        try {
            if(
                self.base_url and
                self.token and
                self.api_url and
                self.session and
                self.webhook_url
            ){
                return True;
            }
            return False;
        } except Exception as e {
            self.logger.error(f"An exception occurred in {self.label}:\n{traceback.format_exc()}\n");
            return False;
        }
    }

    can sanitize_message(message:str) {
        return message.replace("**", "*").replace("<br/>", "\n").replace("<b>", "*").replace("</b>", "*");
    }

    can send_message(session_id:str, message:InteractionMessage, is_group:bool = False, parent_message_id:str = "") {
        # processes an agent response payload format and sends an wppconnect message to a specified session_id via the action

        if(message and session_id) {

            if(not parent_message_id) {
                parent_message_id = message.get_meta('parent_message_id');
            }

            if (message.get_type() == MessageType.SILENCE.value) {}
            elif(message.get_type() == MessageType.TEXT.value) {
                content = self.sanitize_message(message = message.get_content());
                outgoing = Utils.chunk_long_message(message=content, max_length = self.chunk_length, chunk_length = self.chunk_length);

                for chunk in outgoing {
                    self.api().send_message(phone=session_id, message=chunk, is_group=is_group, message_id=parent_message_id);
                }


            } elif(message.get_type() == MessageType.MEDIA.value) {
                mime_type = Utils.get_mime_type(mime_type=message.mime);
                content = self.sanitize_message(message = message.get_content());
                if(mime_type['file_type'] in ["document", "video"]) {
                    self.api().send_file(phone_number= session_id, file_url=message.data.get('url'), filename=message.data.get('file_name'), caption = content);
                } elif(mime_type['file_type'] == "image") {
                    self.api().send_image(phone_number=session_id, file_url= message.data.get('url'), filename=message.data.get('file_name'), caption = content);
                }
            } elif(message.get_type() == MessageType.MULTI.value) {
                for message_item in message.get_content_items() {
                    if(message_item.get_type() == MessageType.TEXT.value) {
                        content = self.sanitize_message(message = message_item.get_content());
                        outgoing = Utils.chunk_long_message(message=content, max_length = self.chunk_length, chunk_length = self.chunk_length);
                        for chunk in outgoing {
                            self.api().send_message(phone=session_id, message=chunk, is_group=is_group, message_id=parent_message_id);
                        }
                    } elif(message_item.get_type() == MessageType.MEDIA.value) {
                        mime_type = Utils.get_mime_type(mime_type=message_item.mime);
                        content = self.sanitize_message(message = message_item.get_content());
                        if(mime_type['file_type'] in ["document", "video"]) {
                            self.api().send_file(phone_number= session_id, file_url=message_item.data.get('url'), filename=message_item.data.get('file_name'), caption = content);
                        }elif(mime_type['file_type'] == "image") {
                            self.api().send_image(phone_number=session_id, file_url= message_item.data.get('url'), filename=message_item.data.get('file_name'), caption = content);
                        }
                    }
                }
            }
        }
    }

    can broadcast_message(message:InteractionMessage, ignore_list:list = []) {
        # processes an agent response payload format and sends a message to all session_ids via the action

        agent_node = self.get_agent();

        if(frames := agent_node.get_memory().get_frames() ) {
            # get all frames then proceed to broadcast
            for frame_node in frames {
                if(frame_node.session_id not in ignore_list) {
                    if(interaction_node := frame_node.get_last_interaction()) {
                        if interaction_node.channel in ['whatsapp'] {
                            self.send_message(session_id = frame_node.session_id, message=message);
                        }
                    }
                }
            }
        }
    }

}
