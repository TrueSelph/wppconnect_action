import:py logging;
import:py from logging { Logger }
import:jac from jivas.agent.core.agent { Agent }
import:jac from jivas.agent.action.action { Action }
import:jac from jivas.agent.action.actions { Actions }
import:jac from jivas.agent.action.interact_graph_walker { interact_graph_walker }
import:jac from jivas.agent.memory.interaction_response {
    MessageType, InteractionMessage, TextInteractionMessage, MediaInteractionMessage, MultiInteractionMessage
}

walker broadcast_message :interact_graph_walker: {
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
    # {
    #     "message": {
    #         "message_type": "MEDIA",
    #         "content": "message content",
    #         "data": {
    #             "url": "https://example.com/image.jpg",
    #             "file_name": "image.jpg"
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
    #                 "data": {
    #                     "url": "https://example.com/image.jpg",
    #                     "file_name": "image.jpg"
    #                 }
    #             }
    #         ]
    #     },
    #     "ignore_list": []
    # }

    # returns a job id

    has message:dict = {};
    has ignore_list:list = [];
    has response:str = '';

    # set up logger
    static has logger:Logger = logging.getLogger(__name__);

    obj __specs__ {
        # make this walker visible in API
        static has private: bool = False;
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
    }

}