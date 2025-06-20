import:py from jivas.agent.modules.agentlib.utils { Utils }
import:jac from jivas.agent.core.graph_node { GraphNode }

node Jobs :GraphNode: {
    has batch_id:str = "";
    has callback_url:str = ""; 
    has created_at:str = "";
    has total:int = 0;
    has success_rate:float = 0.0;
}