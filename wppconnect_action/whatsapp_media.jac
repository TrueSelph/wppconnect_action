import from jivas.agent.core.graph_node { GraphNode }


node WhatsappMedia(GraphNode) {
    has file_url:str = "";
    has data:dict = {};
    has session_id:str = "";
    has created_on:str = "";
}