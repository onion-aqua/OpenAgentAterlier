import type { LAppTextureManager } from './lapptexturemanager';

export interface Live2DGlProvider {
  getGl(): WebGLRenderingContext | WebGL2RenderingContext;
}

export interface Live2DModelHost {
  getCanvas(): HTMLCanvasElement;
  getFrameBuffer(): WebGLFramebuffer;
  getGlManager(): Live2DGlProvider;
  getTextureManager(): LAppTextureManager;
  getShaderBaseUrl(): string;
}
