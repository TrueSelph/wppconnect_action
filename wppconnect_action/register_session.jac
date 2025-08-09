import logging;
import from logging { Logger }
import from jivas.agent.core.agent { Agent }
import from jivas.agent.action.action { Action }
import from jivas.agent.action.actions { Actions }

import from jivas.agent.modules.action.path { action_walker_path }

import from jivas.agent.action.agent_graph_walker { agent_graph_walker }

walker register_session(agent_graph_walker) {

    has response: dict = {};
    has reporting: bool = True;
    has auto_register: bool = False;

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
        self.response = here.register_session(auto_register = self.auto_register);
        if self.reporting {
            report self.response;
        }
    }

}