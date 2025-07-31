import logging;
import os;
import re;
import uuid;
import base64;
import mimetypes;
import from logging { Logger }

import from jivas.agent.modules.action.path { action_webhook_path }

import from .modules.wppconnect_api { WPPConnectAPI }
import from jivas.agent.core.agent { Agent }
import from jivas.agent.memory.frame { Frame }
import from jivas.agent.action.action { Action }
import from jivas.agent.action.interact { interact }
import from jivas.agent.action.action_webhook_walker { action_webhook_walker }
import from jac_cloud.plugin.jaseci { JacPlugin as Jac }


walker wppconnect_interact(action_webhook_walker) {
    # called via a webhook whenever there are verification requests or inbound messages
    # when activated, it will trigger the whatsapp interact action to communicate

    # set up logger
    static has logger:Logger = logging.getLogger(__name__);

    # set up walker as webhook
    class __specs__(action_webhook_walker.__specs__) {
        static has private: bool = False; # make it public
        static has path: str = action_webhook_path(__module__);
    }

    can on_agent with Agent entry {

        # grab payload from webhook call
        payload = self.get_request_json();

        # handle request here to ensure it's worth the walk
        if(not payload) {
            Jac.get_context().status = 200;
            disengage;
        }

        # parse data if we've gotten this far..
        data = WPPConnectAPI.parse_inbound_message(request = payload);

        if(not data) {
            Jac.get_context().status = 200;
            disengage;
        }

        # determine if phone number has access
        if(access_control_action_node := here.get_actions().get(action_label='AccessControlAction')) {

            access = access_control_action_node.has_action_access(
                session_id=data['sender'],
                action_label='WPPConnectAction',
                channel='whatsapp'
            );

            if not access {
                Jac.get_context().status = 200;
                disengage;
            }
        }

        # ignore loopback messages i.e. messages where sender and receiver are the same
        if(data['sender'] == data['receiver']) {
            disengage;
        }

        if( action_node := (here.get_actions().get(action_label='WPPConnectAction')) ) {

            # ignore forwards if set
            if(data.get('isForwarded') and  action_node.ignore_forwards) {
                Jac.get_context().status = 200;
                disengage;
            }

            if(action_node.ignore_newsletters and "@newsletter" in data["sender"]) {
                Jac.get_context().status = 200;
                disengage;
            }

            if(data['fromMe']) {
                # if this is a human sending a message via AI's whatsapp, handle it differently here
                if((data['event_type'] == "onack") and data["author"]) {
                    frame_node = here.get_memory().get_frame(agent_id = here.id, session_id = data["receiver"], force_session=True);
                    self.logger.debug('inserting human message into AI context');
                    frame_node.add_unprompted_interaction(message = data["body"], channel = "whatsapp");
                }
                # we disregard any other fromMe requests
                disengage;
            }

            # init the frame here so we can have it all set up to add the sender info from data
            # we have to force session to get frame to use the session_id we supply, so we can track whatsapp user by number
            frame_node = here.get_memory().get_frame(agent_id = here.id, session_id = data["sender"], force_session=True);

            if(action_node.use_pushname) {
                # grab and save the sender name in a frame variable
                frame_node.set_user_name(data['sender_name']);
            }

            # handle chat message requests
            if(data['message_type'] == 'chat') {
                self.handle_chat_message(
                    data = data,
                    agent_node = here,
                    frame_node = frame_node,
                    action_node = action_node
                );
            }

            # handle voicenote requests
            if(data['message_type'] in ['ptt']) {
                self.handle_voicenote_message(
                    data = data,
                    agent_node = here,
                    frame_node = frame_node,
                    action_node = action_node
                );
            }

            # handle voicenote requests
            if(data['message_type'] in ['audio', 'document', 'image', 'video']) {
                self.handle_media_message(
                    data = data,
                    agent_node = here,
                    frame_node = frame_node,
                    action_node = action_node
                );
            }


            # handle poll requests
            if(data['message_type'] in ['poll']) {
                self.handle_poll_message(
                    data = data,
                    agent_node = here,
                    frame_node = frame_node,
                    action_node = action_node
                );
            }


            # handle location requests
            if(data['message_type'] in ['location']) {
                self.handle_location_message(
                    data = data,
                    agent_node = here,
                    frame_node = frame_node,
                    action_node = action_node
                );
            }
        }
    }

    def is_directed_message(action_node:Action, data:dict) -> bool {
        # interprets the data to determine whether it's a direct group reply or valid direct chat with content

        if(data.get('isGroup')) {
            # first attempt efficient method of determining whether we have a tagged message

            # Look for @[receiver code before @] in the body
            ::py::
            match = re.search( r"@(\d+)", (data['body'].strip()) )
            ::py::

            if not match {
                return False;
            }

            tagged_id = match.group(1);
            receiver = data.get('receiver').split('@')[0] if data.get('receiver') else '';
            # Remove all occurrences of the pattern in the body (case-insensitive)
            data['body'] = re.sub(tagged_id, "", data['body'], flags=re.IGNORECASE).strip();

            if(tagged_id == receiver) {
                return True;
            }

            # if we're here, it means we have those group member ID scenarios and will have to search by group ID
            group_id = data.get('sender');
            result = action_node.api().group_members(group_id);
            if result and result.get('status') == 'success' {
                group_members = result.get('response', {});
                # now we search
                for item in group_members {
                    if(item.get('id', {}).get('user') == tagged_id and item.get('formattedName') == 'You') {
                        return True;
                    }
                }
            }

            return False;

        }

        return True;
    }

    def handle_chat_message(data:dict, agent_node:Agent, frame_node:Frame, action_node:Action) {
        if(self.is_directed_message(action_node, data)) {
            # only respond if we have a message and if we are messaged with @ in groups

            # at this point we validated that it warrants a response, let's issue the typing
            action_node.api().set_typing_status(phone=data["sender"], is_group=data["isGroup"]);

            # handle when user replies to a specific, previous message
            # the AI will need to have the quoted message as context along with the current message
            content = data['body'];

            # handle text-based quoted messages for now
            if( data.get("quoted_message") and (data.get("quoted_message", {}).get("type") == "chat") ) {
                quoted_message = data.get("quoted_message").get("body");
                quoted_message_directive = f"Use the quoted message as context when responding to my reply.  Quoted message: '{quoted_message}' Reply: '{content}'";
                interaction_node = frame_node.add_interaction(utterance = content, channel = "whatsapp");
                interaction_node.add_directive(quoted_message_directive);
            }

            message = (root spawn interact(
                utterance = content,
                agent_id = agent_node.id,
                session_id = frame_node.session_id,
                verbose = False,
                reporting = False,
                channel = "whatsapp",
                data = {"whatsapp_chat": data}
            )).message;

            action_node.send_message(session_id=frame_node.session_id, message=message, is_group=data["isGroup"]);

            # let's disable the typing
            action_node.api().set_typing_status(phone=data["sender"], is_group=data["isGroup"], value=False);
        }
    }

    def handle_voicenote_message(data:dict, agent_node:Agent, frame_node:Frame, action_node:Action) {
        # This action downloads the voicenote audio transcribes it and passes it to interact walker as text to be processed

        if(not data['author']) { # sidestep voicenotes in group chats

            # at this point we validated that it warrants a response, let's issue the status
            action_node.api().set_recording_status(phone=data["sender"], is_group=data["isGroup"]);

            message = None;
            transcription = None;
            interact_object = None;

            # load stt action
            if(stt_action := agent_node.get_stt_action()) {
                transcription = stt_action.invoke_base64(
                    audio_base64 = data['media']
                );
            } else {
                self.logger.error('unable to load speech-to-text action');
            }

            if(transcription) {
                interact_object = (root spawn interact(
                    utterance = transcription,
                    agent_id = agent_node.id,
                    session_id = frame_node.session_id,
                    verbose = False,
                    reporting = False,
                    tts = True,
                    channel = "whatsapp",
                    data = {"whatsapp_voicenote": data['media']}
                ));
            }

            # now we grab the response and send it
            if(interact_object) {

                # dereference response for convenience
                has_tts_response = False;

                # check for TTS result in interact_object since tts flag was set to True
                audio_url = interact_object.response.get('response', {}).get('audio_url');

                if(audio_url) {
                    audio_base64 = WPPConnectAPI.file_url_to_base64(file_url=audio_url, force_prefix=False);
                    # sends audio via wppconnect message using url
                    response = action_node.api().send_voice_base64(phone=frame_node.session_id, is_group=data["isGroup"], base64_ptt = audio_base64);

                    if response.get("status") == "success" {
                        has_tts_response = True;
                    }
                }

                if(not has_tts_response) {
                    # fall back on text reply if no tts response generated
                    action_node.send_message(session_id=frame_node.session_id, message=interact_object.message, is_group=data["isGroup"]);
                }

            }

            # let's disable the status
            action_node.api().set_recording_status(phone=data["sender"], is_group=data["isGroup"], value=False);
        }
    }

    def handle_media_message(data:dict, agent_node:Agent, frame_node:Frame, action_node:Action) {
        # add document resource to data node in interaction
        if(self.is_directed_message(action_node, data)) {
            # default utterance
            interact_utterance = f'sent {data['message_type']} file in the chat';
            existing_files_url = [];

            # check for existing media
            existing_media_url = action_node.get_wppconnect_recent_files(session_id=frame_node.session_id, seconds=action_node.recent_files_time_window);
            if existing_media_url {
                interact_utterance = "";
            }


            # at this point we validated that it warrants a response, let's issue the typing
            action_node.api().set_typing_status(phone=data["sender"], is_group=data["isGroup"]);

            # decode base64 encoded data into bytes
            file_data = base64.b64decode(data['media']);
            name = data["message_id"].split(".")[1];
            extension = mimetypes.guess_extension(data['mime_type']);

            # ensure the output filename is without whitespaces and slashes
            output_filename = f"wa_{str(uuid.uuid4())}_{name.replace(" ", "_").replace("/", "_").replace("\\", "_")}{extension}";
            output_file_path = f"media/{frame_node.session_id}/{output_filename}";

            # save document to the file system
            action_node.save_file(output_file_path, file_data);

            # retrieve file url
            file_url = action_node.get_file_url(output_file_path);

            # if the file url is not available, set the source to the filename
            if not file_url {
                self.logger.error(f"Unable to save file {output_filename} to the file system.");
                return;
            }

            data['media'] = file_url;

            message = (root spawn interact(
                utterance = data['caption'] if data['caption'] else interact_utterance,
                agent_id = agent_node.id,
                session_id = frame_node.session_id,
                verbose = False,
                reporting = False,
                channel = "whatsapp",
                data = {"whatsapp_media": data}
            )).message;

            action_node.send_message(session_id=frame_node.session_id, message=message, is_group=data["isGroup"]);

            # let's disable the typing
            action_node.api().set_typing_status(phone=data["sender"], is_group=data["isGroup"], value=False);
        }
    }

    def handle_poll_message(data:dict, agent_node:Agent, frame_node:Frame, action_node:Action) {
        # add document resource to data node in interaction
        if(self.is_directed_message(action_node, data)) {

            # at this point we validated that it warrants a response, let's issue the typing
            action_node.api().set_typing_status(phone=data["sender"], is_group=data["isGroup"]);

            message = (root spawn interact(
                utterance = "Poll Response received.",
                agent_id = agent_node.id,
                session_id = frame_node.session_id,
                verbose = False,
                reporting = False,
                channel = "whatsapp",
                data = {"whatsapp_media": data}
            )).message;

            action_node.send_message(session_id=frame_node.session_id, message=message, is_group=data["isGroup"]);

            # let's disable the typing
            action_node.api().set_typing_status(phone=data["sender"], is_group=data["isGroup"], value=False);
        }
    }

    def handle_location_message(data:dict, agent_node:Agent, frame_node:Frame, action_node:Action) {
        # add document resource to data node in interaction
        if(self.is_directed_message(action_node, data)) {

            message = (root spawn interact(
                utterance = "The user sent their location.",
                agent_id = agent_node.id,
                session_id = frame_node.session_id,
                verbose = False,
                reporting = False,
                channel = "whatsapp",
                data = {"whatsapp_location": data}
            )).message;

            action_node.send_message(session_id=frame_node.session_id, message=message, is_group=data["isGroup"]);
        }
    }
}
