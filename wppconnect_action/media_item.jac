import from datetime { datetime, timezone }
import from jivas.agent.core.graph_node { GraphNode }


node MediaItem(GraphNode) {
    # represents a media item associated with a whatsapp media collection

    has created_on:str = str((datetime.now(timezone.utc)).isoformat());
    has collection_id:str = "";
    has file_url:str = "";
    has media_type:str = "";
    has data:dict = {};

    def get_file_url() -> str {
        return self.file_url;
    }

    def get_media_type() -> str {
        return self.media_type;
    }

    def get_data() -> dict {
        return self.data;
    }
}