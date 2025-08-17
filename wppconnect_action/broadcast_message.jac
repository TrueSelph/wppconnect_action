import logging;
import from logging { Logger }
import from jivas.agent.core.agent { Agent }
import from jivas.agent.action.action { Action }
import from jivas.agent.action.actions { Actions }

import from jivas.agent.modules.action.path { action_walker_path }

import from jivas.agent.action.agent_graph_walker { agent_graph_walker }
import from jivas.agent.memory.interaction_response {
    MessageType, InteractionMessage, TextInteractionMessage, MediaInteractionMessage, MultiInteractionMessage
}

walker broadcast_message(agent_graph_walker) {
    # sends a single message and an optional ignore list to be sent to every session_id known to the agent
    # the structure of the message is as follows:

    # TEXT
    # {
    #     "message": {
    #         "message_type": "TEXT",
    #         "content": "message content"
    #     },
    #     "ignore_list": ["session_id_1", "session_id_2"]
    # }

    # MEDIA
    # This is for sending media files like images, videos, polls etc.
    #
    # Example structure for sending an image:
    # {
    #     "message": {
    #         "message_type": "MEDIA",
    #         "content": "message content",
    #         "mime": "image/jpeg",
    #         "data": {
    #             "url": "https://example.com/image.jpg",
    #             "file_name": "image.jpg"
    #         }
    #     },
    #     "ignore_list": []
    # }
    #
    # Example structure for sending a poll:
    # {
    #     "message": {
    #         "message_type": "MEDIA",
    #         "mime": "jivas/poll",
    #         "data": {
    #             "name": "What's your favorite color?",
    #             "choices": ["Red", "Green", "Blue"],
    #             "options": {"selectableCount": 1},
    #             "duration_minutes": 1440,
    #             "id": "color_poll_q1"
    #         }
    #     },
    #     "ignore_list": []
    # }

    # MULTI
    # {
    #     "message": {
    #         "message_type": "MULTI",
    #         "content": [
    #             {
    #                 "message_type": "TEXT",
    #                 "content": "message content"
    #             },
    #             {
    #                 "message_type": "MEDIA",
    #                 "content": "message content",
    #                 "mime": "image/jpeg",
    #                 "data": {
    #                     "url": "https://example.com/image.jpg",
    #                     "file_name": "image.jpg"
    #                 }
    #             }
    #         ]
    #     },
    #     "ignore_list": []
    # }

    # returns a job id or None if the message is invalid

    has message:dict = {};
    has ignore_list:list = [];
    has response:str = '';
    has reporting:bool = True;

    # set up logger
    static has logger:Logger = logging.getLogger(__name__);

    class __specs__ {
        static has private: bool = False;
        static has path: str = action_walker_path(__module__);
    }

    can on_agent with Agent entry {
        visit [-->](`?Actions);
    }

    can on_actions with Actions entry {
        visit [-->](`?Action)(?enabled==True)(?label=='WPPConnectAction');
    }

    can on_action with Action entry {

        self.logger.warning("Broadcasting message: %s", self.message);

        message_type = self.message.get('message_type');
        # check if the item is a valid message
        if not self.message {
            Jac.get_context().status = 400;
            report "Invalid message format. Expected a dictionary with 'message' and 'to' keys.";
            disengage;
        }
        # check if the item has a message type
        if not message_type {
            Jac.get_context().status = 400;
            report "No message type provided.";
            disengage;
        }

        interaction_message = here.prepare_interaction_message(message=self.message);
        self.response = here.broadcast_message(message=interaction_message, ignore_list=self.ignore_list);

        if self.reporting {
            report self.response;
        }
    }

}