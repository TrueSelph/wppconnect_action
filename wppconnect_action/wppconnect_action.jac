import:py os;
import:py logging;
import:py traceback;
import:py from logging { Logger }
import:py from jivas.agent.modules.agentlib.utils { Utils }
import:py from .modules.wppconnect_api { WppconnectAPI }
import:py from jvserve.lib.agent_interface { AgentInterface }
import:jac from jivas.agent.action.action { Action }
import:jac from jivas.agent.memory.interaction_response { MessageType }

node WppconnectAction :Action: {
    # houses configurations per agent for whatsapp api communications provided by wppconnect api

    # set up logger
    static has logger:Logger = logging.getLogger(__name__);

    has master_key:str = ""; # WPPConnect Server Secret Key
    has base_url:str = ""; # Jivas Base URL
    has api_key:str = ""; # WPPConnect Server API Key for this session
    has api_url:str = ""; # WPPConnect Server URL
    has instance_id:str = ""; # WPPConnect Server Instance ID
    has webhook_url:str = "";
    has webhook_properties:dict = {};
    has chunk_length:int = 1024;
    # when set, the wa push name value is used as the user name
    has use_pushname:bool = True;
    has ignore_newsletters:bool = True;


    can on_enable(){
        registered = self.on_register();
        if(not registered) {
            self.enabled = False;
        }
    }

    can on_register() -> dict{
        try {
            # set credentials
            if(not self.instance_id) {
                agent_name = self.get_agent().name;
                agent_name = agent_name.replace(" ", "_");
                agent_name = agent_name.replace("-", "_");
                self.instance_id = agent_name;
            }

            if (not self.base_url) {
                self.base_url = f"{os.environ.get('JIVAS_BASE_URL','')}";
                if not self.base_url {
                    self.logger.error('JIVAS_BASE_URL is not set');
                    return {};
                }
            }

            if (not self.master_key) {
                self.master_key = f"{os.environ.get('WPP_MASTER_KEY','')}";
                if not self.master_key {
                    self.logger.error('WPP_MASTER_KEY is not set');
                    return {};
                }
            }

            if(not self.api_url) {
                self.api_url = f"{os.environ.get('WPP_API_URL','')}";
                if not self.api_url {
                    self.logger.error('WPP_API_URL is not set');
                    return {};
                }
            }

            # register webhook is enabled
            if(self.enabled) {
                success = True;

                agent_id = self.get_agent().id;
                module_root = self.get_module_root();
                # generate webhook key
                webhook_key = AgentInterface.encrypt_webhook_key(agent_id=agent_id, module_root=module_root, walker="wppconnect_interact");

                if(self.base_url and self.api_url and webhook_key) {
                    self.logger.warning(f"{self.label}: Registering Webhook");
                    # complete the full webhook url
                    self.webhook_url = f'{self.base_url}/webhook/{webhook_key}';
                    result = WppconnectAPI.register_wppconnect_action(self.api_url, self.instance_id, self.api_key, self.master_key, self.webhook_url, wait_qr_code=False);
                    self.instance_id = result["instance_id"];
                    self.api_key = result["api_key"];
                    return result;
                } else {
                    self.logger.error('unable to generate webhook url for wppconnect, missing required parameters');
                }
            }
        } except Exception as e {
            self.logger.error(f"An exception occurred in {self.label}:\n{traceback.format_exc()}\n");
        }
        return {};
    }

    can healthcheck() -> bool {
        try {
            if(
                self.base_url and
                self.api_key and
                self.api_url and
                self.instance_id and
                self.webhook_url and
                self.chunk_length > 1000
            ){
                return True;
            }
            return False;
        } except Exception as e {
            self.logger.error(f"An exception occurred in {self.label}:\n{traceback.format_exc()}\n");
            return False;
        }
    }


    can logout_wppconnect() -> bool {
        return WppconnectAPI.logout(self.api_url, self.api_key, self.instance_id);
    }

    can sanitize_message(message:str) {
        return message.replace("**", "*").replace("<br/>", "\n").replace("<b>", "*").replace("</b>", "*");
    }

    can send_message(session_id:str, message:InteractionMessage, is_group:bool = False, parent_message_id:str = "") {
        # processes an agent response payload format and sends an wppconnect message to a specified session_id via the action

        if(message and session_id) {
            if(not parent_message_id){
                parent_message_id = message.get_meta('parent_message_id');
            }

            if (message.get_type() == MessageType.SILENCE.value) {}
            elif(message.get_type() == MessageType.TEXT.value) {
                content = self.sanitize_message(message = message.get_content());
                outgoing = Utils.chunk_long_message(message=content, max_length = self.chunk_length, chunk_length = self.chunk_length);

                for chunk in outgoing {
                    WppconnectAPI.send_text_message(phone_number=session_id, message=chunk, api_url=self.api_url, api_key=self.api_key, session_id=self.instance_id, is_group=is_group, msg_id=parent_message_id);
                }
            } elif(message.get_type() == MessageType.MEDIA.value) {
                mime_type = Utils.get_mime_type(mime_type=message.mime);
                if(mime_type['file_type'] == "document") {
                    content = self.sanitize_message(message = message.get_content());
                    WppconnectAPI.send_media(phone_number= session_id, media_url=message.data.get('url'), api_url=self.api_url, api_key=self.api_key, session_id=self.instance_id, file_name=message.data.get('file_name'), caption = content);
                }elif(mime_type['file_type'] == "image") {
                    content = self.sanitize_message(message = message.get_content());
                    WppconnectAPI.send_media(phone_number=session_id, media_url= message.data.get('url'), api_url=self.api_url, api_key=self.api_key, session_id=self.instance_id, caption = content);
                }elif(mime_type['file_type'] == "video") {
                    content = self.sanitize_message(message = message.get_content());
                    WppconnectAPI.send_media(phone_number=session_id, media_url= message.data.get('url'), api_url=self.api_url, api_key=self.api_key, session_id=self.instance_id, caption = content);
                }
            } elif(message.get_type() == MessageType.MULTI.value) {
                for message_item in message.get_content_items() {
                    if(message_item.get_type() == MessageType.TEXT.value) {
                        content = self.sanitize_message(message = message_item.get_content());
                        outgoing = Utils.chunk_long_message(message=content, max_length = self.chunk_length, chunk_length = self.chunk_length);

                        for chunk in outgoing {
                            WppconnectAPI.send_text_message(phone_number=session_id, message=chunk, api_url=self.api_url, api_key=self.api_key, session_id=self.instance_id, is_group=is_group, msg_id=parent_message_id);
                        }
                    } elif(message_item.get_type() == MessageType.MEDIA.value) {
                        mime_type = Utils.get_mime_type(mime_type=message_item.mime);
                        content = self.sanitize_message(message = message_item.get_content());
                        if(mime_type['file_type'] == "document") {
                            WppconnectAPI.send_media(phone_number= session_id, media_url=message_item.data.get('url'), api_url=self.api_url, api_key=self.api_key, session_id=self.instance_id, file_name=message_item.data.get('file_name'), caption = content);
                        } elif(mime_type['file_type'] == "image") {
                            WppconnectAPI.send_media(phone_number=session_id, media_url= message_item.data.get('url'), api_url=self.api_url, api_key=self.api_key, session_id=self.instance_id, caption = content);
                        } elif(mime_type['file_type'] == "video") {
                            WppconnectAPI.send_media(phone_number=session_id, media_url= message_item.data.get('url'), api_url=self.api_url, api_key=self.api_key, session_id=self.instance_id, caption = content);
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
