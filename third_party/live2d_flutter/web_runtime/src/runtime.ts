/**
 * Flutter bridge derived from Live2D/CubismWebSamples 5-r.5.
 * Cubism Framework and Sample-derived code retain their upstream licenses.
 */

import {
  CubismFramework,
  LogLevel,
  Option
} from '@framework/live2dcubismframework';
import { CubismMatrix44 } from '@framework/math/cubismmatrix44';
import { CubismWebGLOffscreenManager } from '@framework/rendering/cubismoffscreenmanager';

import { LAppModel } from './lappmodel';
import { LAppTextureManager } from './lapptexturemanager';
import type { Live2DModelHost } from './runtime_host';

const views = new Map<number, Live2DCanvasRuntime>();
let frameworkReferences = 0;

function retainFramework(): void {
  if (frameworkReferences++ > 0) return;

  const option = new Option();
  option.logFunction = (message: string): void => {
    console.debug(`[FlutterLive2D] ${message}`);
  };
  option.loggingLevel = LogLevel.LogLevel_Warning;
  if (!CubismFramework.startUp(option)) {
    frameworkReferences = 0;
    throw new Error('Cubism Framework failed to start.');
  }
  CubismFramework.initialize();
}

function releaseFramework(): void {
  frameworkReferences = Math.max(0, frameworkReferences - 1);
  if (frameworkReferences == 0) CubismFramework.dispose();
}

class Live2DCanvasRuntime implements Live2DModelHost {
  private readonly gl: WebGL2RenderingContext;
  private readonly textureManager = new LAppTextureManager();
  private readonly frameBuffer: WebGLFramebuffer;
  private readonly resizeObserver: ResizeObserver;
  private model: LAppModel = null;
  private animationFrame = 0;
  private lastFrameTime = performance.now();
  private paused = false;
  private disposed = false;
  private pointerId: number = null;
  private loadGeneration = 0;
  private renderedFrames = 0;

  public constructor(
    private readonly canvas: HTMLCanvasElement,
    private readonly shaderBaseUrl: string
  ) {
    const gl = canvas.getContext('webgl2', {
      alpha: true,
      antialias: true,
      depth: true,
      premultipliedAlpha: true
    });
    if (!gl) throw new Error('This browser does not support WebGL2.');

    this.gl = gl;
    this.frameBuffer = gl.getParameter(gl.FRAMEBUFFER_BINDING);
    this.textureManager.setGlManager(this);
    retainFramework();

    this.canvas.addEventListener('pointerdown', this.onPointerDown);
    this.canvas.addEventListener('pointermove', this.onPointerMove);
    this.canvas.addEventListener('pointerup', this.onPointerUp);
    this.canvas.addEventListener('pointercancel', this.onPointerUp);
    this.canvas.addEventListener('webglcontextlost', this.onContextLost);

    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(canvas);
    this.resize();
    this.animationFrame = requestAnimationFrame(this.renderFrame);
  }

  public getCanvas(): HTMLCanvasElement {
    return this.canvas;
  }

  public getFrameBuffer(): WebGLFramebuffer {
    return this.frameBuffer;
  }

  public getGlManager(): Live2DCanvasRuntime {
    return this;
  }

  public getGl(): WebGL2RenderingContext {
    return this.gl;
  }

  public getTextureManager(): LAppTextureManager {
    return this.textureManager;
  }

  public getShaderBaseUrl(): string {
    return this.shaderBaseUrl;
  }

  public async loadModel(modelDir: string, modelFileName: string): Promise<boolean> {
    this.ensureActive();
    this.unloadModel();
    const generation = ++this.loadGeneration;

    const baseUrl = new URL(ensureTrailingSlash(modelDir), document.baseURI).href;
    const modelUrl = new URL(modelFileName, baseUrl).href;
    const response = await fetch(modelUrl);
    if (!response.ok) {
      throw new Error(`Failed to load ${modelUrl}: HTTP ${response.status}.`);
    }

    const model = new LAppModel();
    model.setSubdelegate(this);
    this.model = model;
    model.loadAssets(baseUrl, modelFileName);

    const deadline = performance.now() + 60000;
    while (!model.isReady()) {
      if (this.disposed || this.model !== model || generation !== this.loadGeneration) {
        throw new Error('Model loading was cancelled.');
      }
      if (performance.now() > deadline) {
        this.unloadModel();
        throw new Error(`Timed out while loading ${modelFileName}.`);
      }
      await new Promise<void>(resolve => setTimeout(resolve, 16));
    }

    this.canvas.dataset.live2dLoaded = 'true';
    return true;
  }

  public unloadModel(): void {
    this.loadGeneration++;
    if (this.model) {
      this.model.release();
      this.model = null;
    }
    this.textureManager.releaseTextures();
    this.canvas.dataset.live2dLoaded = 'false';
  }

  public setRenderingPaused(paused: boolean): void {
    this.ensureActive();
    this.paused = paused;
    this.lastFrameTime = performance.now();
  }

  public startMotion(group: string, index: number, priority: number): void {
    this.requireModel().startMotion(group, index, priority);
  }

  public setExpression(index: number): void {
    this.requireModel().setExpressionByIndex(index);
  }

  public setParameter(parameterId: string, value: number): void {
    this.requireModel().setParameterValue(parameterId, value);
  }

  public setMotionSpeed(speed: number): void {
    if (!Number.isFinite(speed) || speed < 0) {
      throw new Error('Motion speed must be a finite value greater than or equal to zero.');
    }
    this.requireModel().setMotionSpeed(speed);
  }

  public dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    cancelAnimationFrame(this.animationFrame);
    this.resizeObserver.disconnect();
    this.canvas.removeEventListener('pointerdown', this.onPointerDown);
    this.canvas.removeEventListener('pointermove', this.onPointerMove);
    this.canvas.removeEventListener('pointerup', this.onPointerUp);
    this.canvas.removeEventListener('pointercancel', this.onPointerUp);
    this.canvas.removeEventListener('webglcontextlost', this.onContextLost);
    this.unloadModel();
    this.textureManager.release();
    releaseFramework();
  }

  private readonly renderFrame = (timestamp: number): void => {
    if (this.disposed) return;
    this.animationFrame = requestAnimationFrame(this.renderFrame);
    this.resize();

    const delta = Math.min((timestamp - this.lastFrameTime) / 1000, 0.1);
    this.lastFrameTime = timestamp;
    if (this.paused) return;

    this.gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    this.gl.clearColor(0.0, 0.0, 0.0, 0.0);
    this.gl.clearDepth(1.0);
    this.gl.enable(this.gl.DEPTH_TEST);
    this.gl.depthFunc(this.gl.LEQUAL);
    this.gl.enable(this.gl.BLEND);
    this.gl.blendFunc(this.gl.SRC_ALPHA, this.gl.ONE_MINUS_SRC_ALPHA);
    this.gl.clear(this.gl.COLOR_BUFFER_BIT | this.gl.DEPTH_BUFFER_BIT);

    const model = this.model;
    if (!model?.isReady() || !model.getModel()) return;

    const offscreenManager = CubismWebGLOffscreenManager.getInstance();
    offscreenManager.beginFrameProcess(this.gl);
    try {
      const projection = new CubismMatrix44();
      if (model.getModel().getCanvasWidth() > 1.0 && this.canvas.width < this.canvas.height) {
        model.getModelMatrix().setWidth(2.0);
        projection.scale(1.0, this.canvas.width / this.canvas.height);
      } else {
        projection.scale(this.canvas.height / this.canvas.width, 1.0);
      }
      model.update(delta);
      model.draw(projection);
      this.gl.flush();
      this.renderedFrames++;
      if (this.renderedFrames == 1 || this.renderedFrames % 60 == 0) {
        this.canvas.dataset.live2dFrames = String(this.renderedFrames);
      }
    } finally {
      offscreenManager.endFrameProcess(this.gl);
      offscreenManager.releaseStaleRenderTextures(this.gl);
    }
  };

  private resize(): void {
    const pixelRatio = window.devicePixelRatio || 1;
    const width = Math.max(1, Math.round(this.canvas.clientWidth * pixelRatio));
    const height = Math.max(1, Math.round(this.canvas.clientHeight * pixelRatio));
    if (this.canvas.width == width && this.canvas.height == height) return;
    this.canvas.width = width;
    this.canvas.height = height;
    this.gl.viewport(0, 0, width, height);
    this.model?.setRenderTargetSize(width, height);
  }

  private readonly onPointerDown = (event: PointerEvent): void => {
    this.pointerId = event.pointerId;
    this.canvas.setPointerCapture(event.pointerId);
    this.updateDragging(event);
  };

  private readonly onPointerMove = (event: PointerEvent): void => {
    if (event.pointerId == this.pointerId) this.updateDragging(event);
  };

  private readonly onPointerUp = (event: PointerEvent): void => {
    if (event.pointerId != this.pointerId) return;
    this.pointerId = null;
    this.model?.setDragging(0.0, 0.0);
  };

  private readonly onContextLost = (event: Event): void => {
    event.preventDefault();
    this.paused = true;
    console.error('[FlutterLive2D] WebGL context was lost. Recreate the view to recover.');
  };

  private updateDragging(event: PointerEvent): void {
    const rect = this.canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;
    const x = ((event.clientX - rect.left) / rect.width) * 2.0 - 1.0;
    const y = 1.0 - ((event.clientY - rect.top) / rect.height) * 2.0;
    this.model?.setDragging(x, y);
  }

  private requireModel(): LAppModel {
    this.ensureActive();
    if (!this.model?.isReady()) throw new Error('No Live2D model is loaded.');
    return this.model;
  }

  private ensureActive(): void {
    if (this.disposed) throw new Error('Live2D Web view has been disposed.');
  }
}

function ensureTrailingSlash(value: string): string {
  return value.endsWith('/') ? value : `${value}/`;
}

function requireView(viewId: number): Live2DCanvasRuntime {
  const view = views.get(viewId);
  if (!view) throw new Error(`VIEW_NOT_FOUND: ${viewId}`);
  return view;
}

const api = {
  async createView(
    viewId: number,
    canvas: HTMLCanvasElement,
    shaderBaseUrl: string
  ): Promise<void> {
    views.get(viewId)?.dispose();
    canvas.dataset.live2dViewId = String(viewId);
    views.set(viewId, new Live2DCanvasRuntime(canvas, shaderBaseUrl));
  },

  async disposeView(viewId: number): Promise<void> {
    views.get(viewId)?.dispose();
    views.delete(viewId);
  },

  async loadModel(
    viewId: number,
    modelDir: string,
    modelFileName: string
  ): Promise<boolean> {
    return requireView(viewId).loadModel(modelDir, modelFileName);
  },

  async unloadModel(viewId: number): Promise<void> {
    requireView(viewId).unloadModel();
  },

  async setRenderingPaused(viewId: number, paused: boolean): Promise<void> {
    requireView(viewId).setRenderingPaused(paused);
  },

  async startMotion(
    viewId: number,
    group: string,
    index: number,
    priority: number
  ): Promise<void> {
    requireView(viewId).startMotion(group, index, priority);
  },

  async setExpression(viewId: number, index: number): Promise<void> {
    requireView(viewId).setExpression(index);
  },

  async setParameter(
    viewId: number,
    parameterId: string,
    value: number
  ): Promise<void> {
    requireView(viewId).setParameter(parameterId, value);
  },

  async setMotionSpeed(viewId: number, speed: number): Promise<void> {
    requireView(viewId).setMotionSpeed(speed);
  }
};

(window as Window & { FlutterLive2DWeb?: typeof api }).FlutterLive2DWeb = api;
