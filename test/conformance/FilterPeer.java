package io.github.libtmux;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.libtmux.jackson.FilterJson;
import io.github.libtmux.jackson.LibTmuxModels;
import io.github.libtmux.snapshot.PaneState;
import io.github.libtmux.snapshot.WindowContext;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Optional;
import java.util.OptionalLong;

/** Scalar conformance over real Pane accessors; no transport is constructed. */
public final class FilterPeer {
    public static void main(String[] args) throws Exception {
        var json = new ObjectMapper();
        JsonNode fixture = json.readTree(Path.of(args[0]).toFile());
        var panes = new ArrayList<Pane>();
        var context = new WindowContext(new SessionId("$1"), new WindowIndex(2), new WindowId("@1"));
        for (JsonNode row : fixture.get("panes")) {
            var state = new PaneState(context, new PaneId(row.get("pane_id").asText()),
                    row.get("pane_index").asInt(), row.get("pane_active").asBoolean(),
                    row.get("pane_current_command").asText(),
                    new Dimensions(row.get("pane_width").asInt(), row.get("pane_height").asInt()),
                    new PanePosition(row.get("pane_left").asInt(), row.get("pane_top").asInt()),
                    row.get("pane_title").asText(), row.get("pane_current_path").asText(),
                    OptionalLong.empty(), new PaneEdges(false, false, false, false), Optional.empty());
            panes.add(new Pane(null, null, state));
        }
        var results = json.createArrayNode();
        for (JsonNode item : fixture.get("cases")) {
            var expression = FilterJson.read(item.get("query"), LibTmuxModels.pane());
            var result = results.addObject();
            result.set("name", item.get("name"));
            var matches = result.putArray("matches");
            for (var pane : panes) {
                if (expression.test(pane)) matches.add(pane.id().value());
            }
            result.set("encoded", FilterJson.write(expression, LibTmuxModels.pane()));
        }
        System.out.println(json.writeValueAsString(results));
    }
}
