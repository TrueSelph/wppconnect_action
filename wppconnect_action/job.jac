import from jivas.agent.core.graph_node { GraphNode }
import from actions.jivas.wppconnect_action.outbox_item { OutboxItem }


node Job(GraphNode) {
    has job_id:str = "";
    has callback_url:str = "";
    has created_at:str = "";
    has total:int = 0;
    has success_rate:float = 0.0;

    def get_job() -> list {
        # retrieves a list of outbox items
        return [-->](`?OutboxItem);
    }
}
