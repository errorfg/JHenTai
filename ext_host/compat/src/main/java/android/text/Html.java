package android.text;

import org.jsoup.Jsoup;
import org.jsoup.nodes.Element;
import org.jsoup.nodes.Node;
import org.jsoup.nodes.TextNode;
import org.jsoup.select.NodeTraversor;
import org.jsoup.select.NodeVisitor;

/** Html.fromHtml as plain text: block elements and &lt;br&gt; become line breaks. */
public class Html {
    public static final int FROM_HTML_MODE_LEGACY = 0;
    public static final int FROM_HTML_MODE_COMPACT = 63;

    public static Spanned fromHtml(String source) {
        return fromHtml(source, FROM_HTML_MODE_LEGACY);
    }

    public static Spanned fromHtml(String source, int flags) {
        StringBuilder out = new StringBuilder();
        if (source != null) {
            NodeTraversor.traverse(new NodeVisitor() {
                @Override
                public void head(Node node, int depth) {
                    if (node instanceof TextNode) {
                        out.append(((TextNode) node).text());
                    } else if (node instanceof Element) {
                        String tag = ((Element) node).normalName();
                        if (tag.equals("br")) out.append('\n');
                        else if (isBlock(tag) && out.length() > 0 && out.charAt(out.length() - 1) != '\n') out.append('\n');
                    }
                }

                @Override
                public void tail(Node node, int depth) {
                    if (node instanceof Element && isBlock(((Element) node).normalName())) {
                        out.append(flags == FROM_HTML_MODE_LEGACY ? "\n\n" : "\n");
                    }
                }
            }, Jsoup.parseBodyFragment(source).body());
        }
        String text = out.toString().replaceAll("\n{3,}", "\n\n").trim();
        return new SpannedString(text);
    }

    private static boolean isBlock(String tag) {
        switch (tag) {
            case "p": case "div": case "li": case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": case "blockquote": case "ul": case "ol":
                return true;
            default:
                return false;
        }
    }
}
