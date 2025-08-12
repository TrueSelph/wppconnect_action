import from jivas.agent.core.graph_node { GraphNode }
import from actions.jivas.wppconnect_action.outbox_item_status { OutboxItemStatus }

node OutboxItem(GraphNode) {
    has item_id:str = "";
    has added_at:str = "";
    has message:dict = {};
    has session_id:str = "";
    has status:OutboxItemStatus = OutboxItemStatus.PENDING;
}