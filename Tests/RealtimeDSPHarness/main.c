#include "RealtimeDSP.h"
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { AudioBufferList *list; float *data[4]; unsigned channels[4]; unsigned count, frames; } Buffers;
static Buffers buffers(unsigned count, const unsigned *channels, unsigned frames, float fill) {
    Buffers b = {0}; b.count=count; b.frames=frames;
    b.list=calloc(1, offsetof(AudioBufferList,mBuffers)+count*sizeof(AudioBuffer));
    assert(b.list); b.list->mNumberBuffers=count;
    for(unsigned i=0;i<count;i++) {
        b.channels[i]=channels[i]; b.data[i]=calloc(channels[i]*frames,sizeof(float)); assert(b.data[i]);
        b.list->mBuffers[i]=(AudioBuffer){channels[i],channels[i]*frames*sizeof(float),b.data[i]};
        for(unsigned j=0;j<channels[i]*frames;j++) b.data[i][j]=fill;
    }
    return b;
}
static void release(Buffers b) { for(unsigned i=0;i<b.count;i++) free(b.data[i]); free(b.list); }
static void render(MVRenderState *s, Buffers in, Buffers out) { AudioTimeStamp ts={0}; assert(MVAudioIOProc(0,&ts,in.list,&ts,out.list,&ts,s)==noErr); }
static void zero(Buffers b) { for(unsigned i=0;i<b.count;i++) for(unsigned j=0;j<b.channels[i]*b.frames;j++) assert(b.data[i][j]==0); }
int main(void) {
    const unsigned stereo[]={2}, planar[]={1,1}, mono[]={1}, offset[]={2,1,1}, extra[]={1,1,2};
    unsigned checks=0;
    { MVRenderState *s=MVRenderStateCreate(48000,0,2,1); assert(s);
      Buffers in=buffers(1,stereo,64,0.2f), out=buffers(1,stereo,64,99); render(s,in,out);
      for(unsigned i=0;i<128;i++) assert(out.data[0][i]==in.data[0][i]);
      MVRenderMetrics m=MVRenderReadMetrics(s); assert(m.inputPeak==0.2f&&m.outputPeak==0.2f&&m.callbackCount==1&&m.invalidBuffers==0);
      release(in);release(out);MVRenderStateDestroy(s); checks++; }
    { MVRenderState *s=MVRenderStateCreate(48000,0,2,0); Buffers in=buffers(1,stereo,16,0.5f),out=buffers(1,stereo,16,99); render(s,in,out);zero(out);release(in);release(out);MVRenderStateDestroy(s);checks++; }
    { MVRenderState *s=MVRenderStateCreate(48000,0,2,4); Buffers in=buffers(2,planar,16,0),out=buffers(2,planar,16,99);
      for(unsigned i=0;i<16;i++){in.data[0][i]=i%2?-1:1;in.data[1][i]=-in.data[0][i]*0.25f;}render(s,in,out);
      for(unsigned i=0;i<16;i++){assert(isfinite(out.data[0][i])&&fabsf(out.data[0][i])<0.981f);assert(out.data[1][i]==-out.data[0][i]*0.25f);}
      assert(MVRenderReadMetrics(s).limitedFrames==16);release(in);release(out);MVRenderStateDestroy(s);checks++; }
    { MVRenderState *s=MVRenderStateCreate(44100,2,2,2); Buffers in=buffers(3,offset,8,0),out=buffers(3,extra,8,99);
      for(unsigned i=0;i<8;i++){in.data[0][i*2]=NAN;in.data[0][i*2+1]=NAN;in.data[1][i]=0.1f;in.data[2][i]=-0.2f;}render(s,in,out);
      for(unsigned i=0;i<8;i++){assert(fabsf(out.data[0][i]-0.2f)<1e-6);assert(fabsf(out.data[1][i]+0.4f)<1e-6);assert(out.data[2][i*2]==0&&out.data[2][i*2+1]==0);}
      release(in);release(out);MVRenderStateDestroy(s);checks++; }
    { MVRenderState *s=MVRenderStateCreate(48000,0,1,1); Buffers in=buffers(1,stereo,8,0),out=buffers(1,mono,8,99);for(unsigned i=0;i<8;i++){in.data[0][i*2]=0.6f;in.data[0][i*2+1]=-0.2f;}render(s,in,out);for(unsigned i=0;i<8;i++)assert(fabsf(out.data[0][i]-0.2f)<1e-6);release(in);release(out);MVRenderStateDestroy(s);checks++; }
    { MVRenderState *s=MVRenderStateCreate(48000,0,2,1); Buffers in=buffers(1,stereo,8,0.5f),out=buffers(1,stereo,8,99);
      const float invalid[]={NAN,INFINITY,-INFINITY};for(unsigned i=0;i<3;i++){in.data[0][15]=invalid[i];render(s,in,out);zero(out);}assert(MVRenderReadMetrics(s).invalidBuffers==3);release(in);release(out);MVRenderStateDestroy(s);checks++; }
    { MVRenderState *s=MVRenderStateCreate(48000,0,2,1); Buffers in=buffers(1,stereo,7,0.5f),out=buffers(1,stereo,8,99);render(s,in,out);zero(out);assert(MVRenderReadMetrics(s).invalidBuffers==1);release(in);release(out);MVRenderStateDestroy(s);checks++; }
    { MVRenderState *s=MVRenderStateCreate(48000,0,2,1); Buffers in=buffers(1,mono,8,0.5f),out=buffers(1,stereo,8,99);render(s,in,out);zero(out);release(in);release(out);MVRenderStateDestroy(s);checks++; }
    { MVRenderState *s=MVRenderStateCreate(48000,0,2,1); Buffers in=buffers(1,stereo,8,0.5f),out=buffers(1,stereo,8,99);in.list->mBuffers[0].mDataByteSize--;render(s,in,out);zero(out);in.list->mBuffers[0].mDataByteSize++;in.list->mBuffers[0].mData=NULL;render(s,in,out);zero(out);assert(MVRenderReadMetrics(s).invalidBuffers==2);release(in);release(out);MVRenderStateDestroy(s);checks++; }
    { MVRenderState *s=MVRenderStateCreate(48000,0,2,4); Buffers in=buffers(1,stereo,8,FLT_MAX),out=buffers(1,stereo,8,99);render(s,in,out);for(unsigned i=0;i<16;i++)assert(isfinite(out.data[0][i])&&out.data[0][i]>0.9f&&out.data[0][i]<1);release(in);release(out);MVRenderStateDestroy(s);checks++; }
    { MVRenderState *s=MVRenderStateCreate(48000,0,2,100); Buffers in=buffers(1,stereo,4096,0.1f),out=buffers(1,stereo,4096,99);render(s,in,out);assert(fabsf(out.data[0][0]-0.4f)<1e-6);MVRenderSetGain(s,-1);render(s,in,out);assert(out.data[0][0]>0.39f&&out.data[0][0]<0.4f&&fabsf(out.data[0][8191])<1e-6);MVRenderSetGain(s,NAN);render(s,in,out);assert(out.data[0][8191]==0);release(in);release(out);MVRenderStateDestroy(s);checks++; }
    assert(MVRenderStateCreate(0,0,2,1)==NULL);assert(MVRenderStateCreate(NAN,0,2,1)==NULL);assert(MVRenderStateCreate(48000,UINT32_MAX,2,1)==NULL);assert(MVRenderStateCreate(48000,0,3,1)==NULL);checks++;
    printf("RealtimeDSP: %u checks passed (ASan + UBSan)\n",checks);return 0;
}
