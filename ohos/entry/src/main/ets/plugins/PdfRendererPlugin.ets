// PDF rendering: implements the method-channel protocol of the pdfx package
// (channel io.scer.pdf_renderer, the one pdfx uses on platforms other than
// Android, iOS and macOS) with the system's PDF Kit. pdfx has no OpenHarmony
// implementation.
import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { pdfService } from '@kit.PDFKit';

const TAG = 'PdfRendererPlugin';
const CHANNEL = 'io.scer.pdf_renderer';

class OpenDocument {
  document: pdfService.PdfDocument;
  // a copy of in-memory data, removed when the document closes
  tempFile: string | null;

  constructor(document: pdfService.PdfDocument, tempFile: string | null) {
    this.document = document;
    this.tempFile = tempFile;
  }
}

export default class PdfRendererPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;
  private documents = new Map<string, OpenDocument>();
  // page id -> page; the id is "<document id>/<page number>"
  private pages = new Map<string, pdfService.PdfPage>();
  private nextId = 1;

  getUniqueClassName(): string {
    return TAG;
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    try {
      switch (call.method) {
        case 'open.document.file':
          this.open(call.args as string, null, result);
          break;
        case 'open.document.data':
          this.openData(call.args as Uint8Array, result);
          break;
        case 'close.document':
          this.closeDocument(call.args as string);
          result.success(null);
          break;
        case 'open.page':
          this.openPage(call.argument('documentId') as string, call.argument('page') as number, result);
          break;
        case 'close.page':
          this.pages.delete(call.args as string);
          result.success(null);
          break;
        case 'render':
          this.render(call, result);
          break;
        default:
          result.notImplemented();
      }
    } catch (e) {
      result.error('pdf_renderer', `${call.method}: ${(e as Error).message ?? e}`, null);
    }
  }

  private open(path: string, tempFile: string | null, result: MethodResult): void {
    const document = new pdfService.PdfDocument();
    const parsed = document.loadDocument(path);
    if (parsed !== pdfService.ParseResult.PARSE_SUCCESS) {
      result.error('pdf_renderer', `cannot open the document (result ${parsed})`, null);
      return;
    }
    const id = `${this.nextId++}`;
    this.documents.set(id, new OpenDocument(document, tempFile));
    const reply = new Map<string, Object>();
    reply.set('id', id);
    reply.set('pagesCount', document.getPageCount());
    result.success(reply);
  }

  private openData(data: Uint8Array, result: MethodResult): void {
    const context = this.context;
    if (context == null) {
      result.error('pdf_renderer', 'no ability', null);
      return;
    }
    // PDF Kit loads documents from a path
    const path = `${context.cacheDir}/pdf_renderer_${Date.now()}_${this.nextId}.pdf`;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    } finally {
      fs.closeSync(file);
    }
    this.open(path, path, result);
  }

  private closeDocument(id: string): void {
    const open = this.documents.get(id);
    if (open == null) {
      return;
    }
    this.documents.delete(id);
    const prefix = `${id}/`;
    for (const pageId of Array.from(this.pages.keys())) {
      if (pageId.startsWith(prefix)) {
        this.pages.delete(pageId);
      }
    }
    open.document.releaseDocument();
    if (open.tempFile != null) {
      fs.unlink(open.tempFile).catch(() => {});
    }
  }

  private openPage(documentId: string, pageNumber: number, result: MethodResult): void {
    const open = this.documents.get(documentId);
    if (open == null) {
      result.error('pdf_renderer', 'the document is not open', null);
      return;
    }
    // pdfx counts pages from 1, PDF Kit from 0
    const page = open.document.getPage(pageNumber - 1);
    const id = `${documentId}/${pageNumber}`;
    this.pages.set(id, page);
    const reply = new Map<string, Object>();
    reply.set('id', id);
    reply.set('width', page.getWidth());
    reply.set('height', page.getHeight());
    result.success(reply);
  }

  private render(call: MethodCall, result: MethodResult): void {
    const page = this.pages.get(call.argument('pageId') as string);
    if (page == null) {
      result.error('pdf_renderer', 'the page is not open', null);
      return;
    }
    const width = Math.max(1, Math.round(call.argument('width') as number));
    const height = Math.max(1, Math.round(call.argument('height') as number));
    const format = call.argument('format') as number;
    const quality = (call.argument('quality') as number | null) ?? 100;

    const matrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = width;
    matrix.height = height;
    matrix.rotate = 0;
    const pixelMap = page.getCustomPagePixelMap(matrix, false, true);

    // pdfx: 0 JPEG, 1 PNG, 2 WebP
    const mime = format === 0 ? 'image/jpeg' : (format === 2 ? 'image/webp' : 'image/png');
    const packer = image.createImagePacker();
    packer.packToData(pixelMap, { format: mime, quality: quality }).then((data: ArrayBuffer) => {
      const reply = new Map<string, Object>();
      reply.set('width', width);
      reply.set('height', height);
      reply.set('data', new Uint8Array(data));
      result.success(reply);
    }).catch((e: Error) => {
      result.error('pdf_renderer', `encoding failed: ${e.message}`, null);
    }).finally(() => {
      pixelMap.release();
      packer.release();
    });
  }
}
