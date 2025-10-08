import from datetime { datetime, timezone }
import from jivas.agent.core.graph_node { GraphNode }
import from actions.jivas.wppconnect_action.media_item { MediaItem }
import from actions.jivas.wppconnect_action.media_collection_status { MediaCollectionStatus }
import from jac_cloud.plugin.jaseci { JacPlugin as Jac }


node MediaCollection(GraphNode) {
    # collection of media items, designed to serve as a grouping node for WhatsappMedia items sent in a batch

    has collection_id:str = "";
    has session_id:str = "";
    has status:MediaCollectionStatus = MediaCollectionStatus.OPEN;
    has created_on:str = str((datetime.now(timezone.utc)).isoformat());
    has updated_on:str = str((datetime.now(timezone.utc)).isoformat());

    def get_status() -> MediaCollectionStatus {
        return self.status;
    }

    def close_collection() -> None {
        self.set_status(MediaCollectionStatus.CLOSED);
    }

    def set_status(status:MediaCollectionStatus) -> None {
        # timestamp completed on
        if status in [MediaCollectionStatus.OPEN, MediaCollectionStatus.CLOSED] {
            self.updated_on = str((datetime.now(timezone.utc)).isoformat());
        }
        self.status = status;
    }

    def get_media_items() -> list[MediaItem] {
        # retrieves a list of media items associated with this collection
        return [-->](`?MediaItem);
    }

    def has_media_items() -> bool {
        return len(self.get_media_items()) > 0;
    }

    def export_media_items() -> list[dict] {
        # exports the media items in a serializable format
        media_items = self.get_media_items();
        return [item.export() for item in media_items];
    }

    def add_media_item(file_url:str, media_type:str, data:dict={}) -> MediaItem {
        # adds a media item to this collection

        if not file_url or not media_type {
            return None;
        }

        media_item = MediaItem(
            collection_id = self.collection_id,
            file_url = file_url,
            media_type = media_type,
            data = data
        );

        # now we attach it to the job
        self ++> media_item;

        # update the updated_on timestamp
        self.updated_on = str((datetime.now(timezone.utc)).isoformat());

        return media_item;
    }

    def delete() -> list {
        return (self spawn _purge_media_collection()).removed;
    }
}

walker _purge_media_collection {
    # walker which carries out the traversal and purging of this media collection and any related items

    has removed:list = [];

    obj __specs__ {
        # make this a private walker
        static has private: bool = True;
    }

    can on_collection with MediaCollection entry {
        visit [-->];
        self.removed.append(here);
        Jac.destroy(here);
    }

    can on_media_item with MediaItem entry {
        self.removed.append(here);
        Jac.destroy(here);
    }
}