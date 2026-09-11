// Dedicated parser process. Input is a sealed Linux memfd; outputs are generated
// names in a private job directory. No document paths, actions or URIs are run.
#include <PDFDoc.h>
#include <Page.h>
#include <XRef.h>
#include <Object.h>
#include <GlobalParams.h>
#include <Error.h>
#include <SplashOutputDev.h>
#include <splash/SplashBitmap.h>
#include <goo/GooString.h>
#include <jpeglib.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <memory>
#include <sstream>
#include <set>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {
bool parserError = false;
bool unsupportedJBIG2 = false;
int failureStage = 65;
void onError(ErrorCategory, Goffset, const char *message) {
    parserError = true;
    if (message && std::strcmp(message,"SNAGLIST_UNSUPPORTED_JBIG2")==0) unsupportedJBIG2=true;
}
[[noreturn]] void fail() { throw std::runtime_error("drawing rejected"); }
const PDFRectangle &rectangle(const PDFRectangle &r) { return r; }
const PDFRectangle &rectangle(const PDFRectangle *r) { if (!r) fail(); return *r; }

struct Box {
    double x,y,w,h;
    explicit Box(const PDFRectangle &r):x(r.x1),y(r.y1),w(r.x2-r.x1),h(r.y2-r.y1) {}
    Box(double a,double b,double c,double d):x(a),y(b),w(c),h(d) {}
    void validate() const {
        for (double value:{x,y,w,h,x+w,y+h}) if (!std::isfinite(value)) fail();
        if (w<=0 || h<=0 || x+w<=x || y+h<=y) fail();
    }
    std::string json() const {
        std::ostringstream out;
        out<<std::setprecision(17)<<"{\"x\":"<<x<<",\"y\":"<<y<<",\"width\":"<<w<<",\"height\":"<<h<<"}";
        return out.str();
    }
};

Object inherited(PDFDoc &document, Page *page, const char *key) {
    Ref reference=page->getRef();
    std::set<std::pair<int,int>> visited;
    for (int depth=0;depth<32;depth++) {
        if (!visited.insert({reference.num,reference.gen}).second) fail();
        Object dictionary=document.getXRef()->fetch(reference);
        if (!dictionary.isDict()) fail();
        Object value=dictionary.dictLookup(key);
        if (!value.isNull()) return value;
        const Object &parent=dictionary.dictLookupNF("Parent");
        if (parent.isNull()) return Object(objNull);
        if (!parent.isRef()) fail();
        reference=parent.getRef();
    }
    fail();
}

Box rawBox(const Object &value) {
    if (!value.isArray() || value.arrayGetLength()!=4) fail();
    std::array<double,4> values{};
    for (int i=0;i<4;i++) {
        Object item=value.arrayGet(i);
        if (!item.isNum()) fail();
        values[i]=item.getNum();
    }
    Box box(values[0],values[1],values[2]-values[0],values[3]-values[1]);
    box.validate(); return box;
}

bool sameBox(const Box &a,const Box &b) {
    return std::abs((a.x-b.x)/b.w)<=1e-10 && std::abs((a.y-b.y)/b.h)<=1e-10 &&
        std::abs(a.w/b.w-1)<=1e-10 && std::abs(a.h/b.h-1)<=1e-10;
}

FILE *newFile(int dirfd,const std::string &name) {
    int fd=openat(dirfd,name.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd<0) fail();
    FILE *file=fdopen(fd,"wb");
    if (!file) { close(fd); fail(); }
    return file;
}

// libjpeg's default fatal handler exits the isolated child. No raw parser error
// text is returned to the caller; the supervisor caps and discards diagnostics.
void jpegError(j_common_ptr) { _exit(71); }
size_t writeJPEG(int dirfd,const std::string &name,SplashBitmap *bitmap) {
    if (!bitmap || bitmap->getWidth()<1 || bitmap->getHeight()<1 ||
        bitmap->getWidth()>4096 || bitmap->getHeight()>4096) fail();
    FILE *file=newFile(dirfd,name);
    jpeg_compress_struct jpeg{};
    jpeg_error_mgr errors{};
    jpeg.err=jpeg_std_error(&errors);
    errors.error_exit=jpegError;
    jpeg_create_compress(&jpeg);
    jpeg_stdio_dest(&jpeg,file);
    jpeg.image_width=bitmap->getWidth(); jpeg.image_height=bitmap->getHeight();
    jpeg.input_components=3; jpeg.in_color_space=JCS_RGB;
    jpeg_set_defaults(&jpeg);
    jpeg_set_quality(&jpeg,90,TRUE);
    // Explicit 4:4:4, baseline, no optimisation or metadata. Encoder/profile is pinned.
    for (int i=0;i<3;i++) { jpeg.comp_info[i].h_samp_factor=1; jpeg.comp_info[i].v_samp_factor=1; }
    jpeg.optimize_coding=FALSE;
    jpeg_start_compress(&jpeg,TRUE);
    while (jpeg.next_scanline<jpeg.image_height) {
        JSAMPROW row=bitmap->getDataPtr()+jpeg.next_scanline*bitmap->getRowSize();
        if (jpeg_write_scanlines(&jpeg,&row,1)!=1) fail();
    }
    jpeg_finish_compress(&jpeg); jpeg_destroy_compress(&jpeg);
    if (fflush(file)!=0) fail();
    long size=ftell(file);
    if (fclose(file)!=0 || size<1 || size>10*1024*1024) fail();
    return static_cast<size_t>(size);
}

std::array<double,6> transform(const Box &b,int rotation) {
    switch (rotation) {
    case 0: return {1/b.w,0,0,-1/b.h,-b.x/b.w,1+b.y/b.h};
    case 90: return {0,1/b.w,1/b.h,0,-b.y/b.h,-b.x/b.w};
    case 180: return {-1/b.w,0,0,1/b.h,1+b.x/b.w,-b.y/b.h};
    case 270: return {0,-1/b.w,-1/b.h,0,1+b.y/b.h,1+b.x/b.w};
    default: fail();
    }
}

std::string pageName(const char *prefix,int index) {
    char name[32]; snprintf(name,sizeof(name),"%s-%04d.jpg",prefix,index); return name;
}

int run(int inputfd,int outputfd) {
    failureStage=70;
    struct stat input{};
    if (fstat(inputfd,&input)!=0 || !S_ISREG(input.st_mode) || input.st_size<1 || input.st_size>50*1024*1024) fail();
    int seals=fcntl(inputfd,F_GET_SEALS);
    int required=F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK|F_SEAL_SEAL;
    if (seals!=required) fail();
    failureStage=67;
    setErrorCallback(onError);
    globalParams=std::make_unique<GlobalParams>();
    bool reconstructed=false;
    auto name=std::make_unique<GooString>("/proc/self/fd/"+std::to_string(inputfd));
    // Poppler 22 takes ownership despite its historical const-pointer signature.
    // PDFDoc.cc assigns this pointer and its destructor deletes it exactly once.
    PDFDoc document(name.release(),nullptr,nullptr,nullptr,[&reconstructed](){ reconstructed=true; });
    if (!document.isOk() || parserError || reconstructed || document.isEncrypted()) fail();
    int count=document.getNumPages();
    if (count<1 || count>100 || parserError) fail();
    SplashColor white{255,255,255};
    SplashOutputDev renderer(splashModeRGB8,4,false,white,true);
    renderer.startDoc(&document);
    std::ostringstream metadata; metadata<<std::setprecision(17)<<"{\"pages\":[";
    size_t outputBytes=0;
    for (int index=0;index<count;index++) {
        failureStage=67;
        Page *page=document.getPage(index+1);
        if (!page || !page->isOk() || parserError) fail();
        failureStage=68;
        // Poppler normalises some malformed/inherited boxes and rotations. Keep
        // the parser's raw dictionary facts and reject repairs rather than publish
        // fabricated source geometry. Parent traversal is bounded and cycle-checked.
        Object mediaValue=inherited(document,page,"MediaBox"),cropValue=inherited(document,page,"CropBox");
        Box media=rawBox(mediaValue),crop=cropValue.isNull()?media:rawBox(cropValue);
        double x=std::max(media.x,crop.x), y=std::max(media.y,crop.y);
        Box display(x,y,std::min(media.x+media.w,crop.x+crop.w)-x,std::min(media.y+media.h,crop.y+crop.h)-y);
        display.validate();
        Object rotationValue=inherited(document,page,"Rotate");
        if (!rotationValue.isNull() && !rotationValue.isInt()) fail();
        int rotation=rotationValue.isNull()?0:rotationValue.getInt();
        if (rotation!=0 && rotation!=90 && rotation!=180 && rotation!=270) fail();
        if (page->getRotate()!=rotation || !sameBox(Box(rectangle(page->getMediaBox())),media) ||
            !sameBox(Box(rectangle(page->getCropBox())),display)) fail();
        // UserUnit is a page dictionary entry, not one of the inheritable page
        // attributes. Read it through Poppler's actual object parser, never regex.
        Object dictionary=document.getXRef()->fetch(page->getRef());
        if (!dictionary.isDict()) fail();
        Object unit=dictionary.dictLookup("UserUnit");
        if (!unit.isNull() && !unit.isNum()) fail();
        double userUnit=unit.isNull()?1:unit.getNum();
        if (!std::isfinite(userUnit) || userUnit<=0 || userUnit>75000 ||
            display.w*userUnit>1e7 || display.h*userUnit>1e7) fail();
        // The chosen crop's aspect is independent of uniform UserUnit. Render
        // using a measured pixel target; preserve the raw unit in the geometry.
        double dpi=72*4096/std::max(display.w,display.h);
        if (!std::isfinite(dpi) || dpi<1e-6 || dpi>1e8) fail();
        failureStage=69;
        document.displayPage(&renderer,index+1,dpi,dpi,0,false,true,false);
        if (parserError) fail();
        SplashBitmap *bitmap=renderer.getBitmap();
        int width=bitmap->getWidth(),height=bitmap->getHeight();
        double aspect=(rotation==90||rotation==270)?display.h/display.w:display.w/display.h;
        if (width<1 || height<1 || width>4096 || height>4096 || !std::isfinite(aspect) || aspect<=0 ||
            std::abs(width-height*aspect)>std::max(1.0,aspect)+1e-10) fail();
        failureStage=71;
        outputBytes+=writeJPEG(outputfd,pageName("page",index),bitmap);
        dpi=72*512/std::max(display.w,display.h);
        failureStage=69;
        document.displayPage(&renderer,index+1,dpi,dpi,0,false,true,false);
        if (parserError) fail();
        bitmap=renderer.getBitmap();
        int thumbWidth=bitmap->getWidth(),thumbHeight=bitmap->getHeight();
        if (thumbWidth>512 || thumbHeight>512) fail();
        failureStage=71;
        outputBytes+=writeJPEG(outputfd,pageName("thumb",index),bitmap);
        if (outputBytes>256*1024*1024) fail();
        if (index) metadata<<",";
        metadata<<"{\"sourcePageIndex\":"<<index<<",\"sourcePageLabel\":\""<<index+1<<"\",\"geometry\":{";
        metadata<<"\"mediaBox\":"<<media.json()<<",\"cropBox\":"<<crop.json()<<",\"displayBox\":"<<display.json();
        metadata<<",\"rotation\":"<<rotation<<",\"userUnit\":"<<userUnit<<",\"width\":"<<width<<",\"height\":"<<height;
        metadata<<",\"coordinateSystem\":\"display_top_left_v1\",\"sourceToDisplay\":[";
        auto matrix=transform(display,rotation);
        for (int i=0;i<6;i++) { if (i) metadata<<","; if (!std::isfinite(matrix[i])) fail(); metadata<<matrix[i]; }
        metadata<<"]},\"thumbnailWidth\":"<<thumbWidth<<",\"thumbnailHeight\":"<<thumbHeight<<"}";
    }
    if (parserError || reconstructed) fail();
    metadata<<"]}";
    std::string bytes=metadata.str();
    if (bytes.size()>1024*1024) fail();
    FILE *file=newFile(outputfd,"pages.json");
    if (fwrite(bytes.data(),1,bytes.size(),file)!=bytes.size() || fclose(file)!=0) fail();
    return 0;
}
}

int main(int argc,char **argv) {
    try {
        if (argc!=3) fail();
        char *end=nullptr; long fd=strtol(argv[1],&end,10);
        if (!end || *end || fd<0 || fd>63) fail();
        // The supervisor supplies an inherited directory descriptor through procfs.
        int outputfd=open(argv[2],O_RDONLY|O_DIRECTORY|O_CLOEXEC);
        if (outputfd<0) fail();
        int result=run(static_cast<int>(fd),outputfd); close(outputfd); return result;
    } catch (...) { return unsupportedJBIG2?66:failureStage; }
}
