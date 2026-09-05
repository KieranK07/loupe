#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <pthread.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/vnode.h>
#include <limits.h>
#define BUFSZ (256*1024)

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cv = PTHREAD_COND_INITIALIZER;
static char **stk; static size_t sn=0, scap=0; static int active=0, nthreads=0, done=0;
typedef struct { unsigned long long files,dirs,err,hl,dl,alloc,logical,namebytes,maxdepth,over255,big4g; } Acc;

static void push_locked(const char*p){
  if(sn==scap){ scap = scap? scap*2:4096; stk = realloc(stk, scap*sizeof(char*)); }
  stk[sn++] = strdup(p);
}
static void push_owned_locked(char*p){
  if(sn==scap){ scap = scap? scap*2:4096; stk = realloc(stk, scap*sizeof(char*)); }
  stk[sn++] = p;
}
static unsigned long long n_trunc=0;
static void walk_dir(const char *path, Acc *a, char *buf){
  int fd = open(path, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(fd<0){ a->err++; return; }
  struct attrlist al; memset(&al,0,sizeof al);
  al.bitmapcount = ATTR_BIT_MAP_COUNT;
  al.commonattr = ATTR_CMN_RETURNED_ATTRS|ATTR_CMN_NAME|ATTR_CMN_DEVID|ATTR_CMN_OBJTYPE
                | ATTR_CMN_MODTIME|ATTR_CMN_FLAGS|ATTR_CMN_FILEID|ATTR_CMN_ERROR;
  al.fileattr = ATTR_FILE_LINKCOUNT|ATTR_FILE_TOTALSIZE|ATTR_FILE_ALLOCSIZE;
  char **kids=NULL; size_t nk=0, kcap=0; int count;
  while((count=getattrlistbulk(fd,&al,buf,BUFSZ,0))>0){
    char *e=buf;
    for(int i=0;i<count;i++){
      char *f=e; uint32_t entlen; memcpy(&entlen,f,4); f+=4;
      attribute_set_t ret; memcpy(&ret,f,sizeof ret); f+=sizeof ret;
      const char*name=NULL; uint32_t ot=0,fl=0,er=0,lc=0; uint64_t al2=0,lg=0;
      if(ret.commonattr&ATTR_CMN_NAME){ attrreference_t ar; memcpy(&ar,f,sizeof ar); name=f+ar.attr_dataoffset; f+=sizeof ar; }
      if(ret.commonattr&ATTR_CMN_DEVID) f+=sizeof(dev_t);
      if(ret.commonattr&ATTR_CMN_OBJTYPE){ memcpy(&ot,f,4); f+=4; }
      if(ret.commonattr&ATTR_CMN_MODTIME) f+=sizeof(struct timespec);
      if(ret.commonattr&ATTR_CMN_FLAGS){ memcpy(&fl,f,4); f+=4; }
      if(ret.commonattr&ATTR_CMN_FILEID) f+=8;
      if(ret.commonattr&ATTR_CMN_ERROR){ memcpy(&er,f,4); f+=4; }
      if(ret.fileattr&ATTR_FILE_LINKCOUNT){ memcpy(&lc,f,4); f+=4; }
      if(ret.fileattr&ATTR_FILE_TOTALSIZE){ memcpy(&lg,f,8); f+=8; }
      if(ret.fileattr&ATTR_FILE_ALLOCSIZE){ memcpy(&al2,f,8); f+=8; }
      if(er){ a->err++; e+=entlen; continue; }
      if(name){ size_t nl=strlen(name); a->namebytes+=nl+1; if(nl>255) a->over255++; }
      { size_t d=0; for(const char*q=path;*q;q++) if(*q=='/') d++; if(d>a->maxdepth) a->maxdepth=d; }
      if(fl & SF_DATALESS) a->dl++;
      if(ot==VDIR){ a->dirs++;
        if(name && !(fl&SF_FIRMLINK)){
          char tmp[PATH_MAX];
          int need = snprintf(tmp,sizeof tmp,"%s/%s",path,name);
          if(need > 0 && (size_t)need < sizeof tmp){          /* skip, never push, a truncated path */
            if(nk==kcap){ kcap = kcap? kcap*2:64; kids=realloc(kids,kcap*sizeof(char*)); }
            kids[nk++] = strdup(tmp);
          } else { __atomic_fetch_add(&n_trunc,1,__ATOMIC_RELAXED); }
        } }
      else if(ot==VREG){ a->files++; if(lc>1) a->hl++; a->alloc+=al2; a->logical+=lg; if(al2>=(1ULL<<32)||lg>=(1ULL<<32)) a->big4g++; }
      e+=entlen;
    }
  }
  close(fd);
  if(nk){ pthread_mutex_lock(&mu); for(size_t i=0;i<nk;i++) push_owned_locked(kids[i]); pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu); }
  free(kids);
}
static void* worker(void*arg){
  Acc *a = (Acc*)arg; char *buf = malloc(BUFSZ);
  for(;;){
    pthread_mutex_lock(&mu);
    while(sn==0 && !done){ if(--active==0 && sn==0){ done=1; pthread_cond_broadcast(&cv); } else pthread_cond_wait(&cv,&mu); if(done) break; active++; }
    if(sn==0 && done){ pthread_mutex_unlock(&mu); break; }
    char *p = stk[--sn]; pthread_mutex_unlock(&mu);
    walk_dir(p,a,buf); free(p);
  }
  free(buf); return NULL;
}
int main(int argc,char**argv){
  if(argc<3){ fprintf(stderr,"usage: pwalk <path> <threads>\n"); return 2; }
  setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,IOPOL_SCOPE_PROCESS,IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
  nthreads = atoi(argv[2]); active = nthreads;
  Acc *accs = calloc(nthreads,sizeof(Acc));
  pthread_t *th = calloc(nthreads,sizeof(pthread_t));
  push_locked(argv[1]);
  struct timespec t0,t1; clock_gettime(CLOCK_MONOTONIC,&t0);
  for(int i=0;i<nthreads;i++) pthread_create(&th[i],NULL,worker,&accs[i]);
  for(int i=0;i<nthreads;i++) pthread_join(th[i],NULL);
  clock_gettime(CLOCK_MONOTONIC,&t1);
  double el=(t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)/1e9;
  Acc t={0}; for(int i=0;i<nthreads;i++){ t.files+=accs[i].files;t.dirs+=accs[i].dirs;t.err+=accs[i].err;t.hl+=accs[i].hl;t.dl+=accs[i].dl;t.alloc+=accs[i].alloc;t.logical+=accs[i].logical;t.namebytes+=accs[i].namebytes;t.over255+=accs[i].over255;t.big4g+=accs[i].big4g; if(accs[i].maxdepth>t.maxdepth) t.maxdepth=accs[i].maxdepth; }
  unsigned long long tot=t.files+t.dirs;
  printf("namebytes=%.1f MiB  avg=%.1f B/name  names>255B=%llu  files>=4GiB=%llu  maxdepth=%llu\n",
         t.namebytes/1048576.0, (double)t.namebytes/(tot?tot:1), t.over255, t.big4g, t.maxdepth);
  printf("j=%-2d  %8llu entries  %7.3fs  %8.0f ent/s   phys=%.1fGiB log=%.1fGiB dataless=%llu trunc=%llu\n",
         nthreads, tot, el, tot/el, t.alloc/1073741824.0, t.logical/1073741824.0, t.dl, n_trunc);
  return 0;
}
