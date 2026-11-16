// Where the web views that Tachiyomi extensions use live in the window: a
// node under the app's own content (pages/Index.ets puts it below the
// Flutter view). The views are part of the window like any page of a
// browser, so the engine lays them out and runs them as visible pages; they
// are covered by the app's content and take no touches.
import { FrameNode, NodeController, UIContext } from '@kit.ArkUI';

export class TachiWebHost extends NodeController {
  private root: FrameNode | null = null;
  private context: UIContext | null = null;
  private waiting: Array<(root: FrameNode) => void> = [];

  makeNode(uiContext: UIContext): FrameNode | null {
    if (this.root == null) {
      const root = new FrameNode(uiContext);
      root.commonAttribute.width('100%').height('100%');
      this.root = root;
      this.context = uiContext;
      const waiting = this.waiting;
      this.waiting = [];
      for (const action of waiting) {
        action(root);
      }
    }
    return this.root;
  }

  /// The UI context of the page the node belongs to; null before [ready].
  uiContext(): UIContext | null {
    return this.context;
  }

  /// The node the views are children of, once the page has been built.
  ready(): Promise<FrameNode> {
    const root = this.root;
    if (root != null) {
      return Promise.resolve(root);
    }
    return new Promise<FrameNode>((resolve: (root: FrameNode) => void) => {
      this.waiting.push(resolve);
    });
  }
}

export const tachiWebHost = new TachiWebHost();
