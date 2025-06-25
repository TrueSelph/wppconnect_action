import:py from jivas.agent.modules.agentlib.utils { Utils }
import:jac from jivas.agent.core.graph_node { GraphNode }
import:jac from actions.jivas.wppconnect_action.job_status { JobStatus }

node Job :GraphNode: {
    has id:str = "";
    has added_at:str = "";
    has message:dict = {};
    has session_id:str = "";
    has status:JobStatus = JobStatus.PENDING;
}