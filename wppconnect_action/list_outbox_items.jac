import logging;
import from logging { Logger }
import from jivas.agent.core.agent { Agent }
import from jivas.agent.action.action { Action }
import from jivas.agent.action.actions { Actions }
import from jivas.agent.action.agent_graph_walker { agent_graph_walker }

walker list_outbox_items(agent_graph_walker) {

    has page:int = 1;
    has limit:int = 10;
    has all:bool = False;  # new flag to indicate whether to return all documents
    has filtered_status:str = [];
    has filtered_job_id:str = [];
    has response:list[dict] = [];


    # set up logger
    static has logger:Logger = logging.getLogger(__name__);

    obj __specs__ {
        # make this walker visible in API
        static has private: bool = True;
    }

    can on_agent with Agent entry {
        visit [-->](`?Actions);
    }

    can on_actions with Actions entry {
        visit [-->](`?Action)(?enabled==True)(?label=='WPPConnectAction');
    }

    can on_action with Action entry {
        if self.all {
            self.response = here.list_outbox_items(page=self.page, limit=0, filtered_status=self.filtered_status, filtered_job_id=self.filtered_job_id);  # fetch all documents
        } else {
            self.response = here.list_outbox_items(page=self.page, limit=self.limit, filtered_status=self.filtered_status, filtered_job_id=self.filtered_job_id);  # fetch paged documents
        }
    }

}