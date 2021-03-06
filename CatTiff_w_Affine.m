%% Load and Motion Correct

% This first part just creates a cell array of filenames to load, may have
% to be changed if you're names are different than Alice's
clear all;
close all;
%get all files names
num_files = 6;
nameOffset = 0;
mouse_name = 'LD085';
session_name = '131125';
view_name = 'view1';
slice_name = 'slice2';
tiffpath = cd;

for j=1:num_files
%     [tifffilename,tiffpath]=uigetfile('*.tif','pick your tiff file');
%     eval(['fullfilename' num2str(j) ' = [tiffpath tifffilename]']);
filenames{j} = sprintf('%s_%s_%.3d_%s_%s.tif.tif',mouse_name,session_name,j+nameOffset,view_name,slice_name);
end



%open files and concatenate; scale for same instensities
cated_movie=[];
cated_xShift = [];
cated_yShift = [];
acqRef = [];
for j=1:num_files

    %eval(['fullfilename=fullfilename' num2str(j)]);
    fullfilename = filenames{j};
    info=imfinfo(fullfilename);
    numframes(j)=length(info);
    M=info(1).Width;
    N=info(1).Height;
    Z=numframes(j);

    chone=zeros(N,M,Z,'single');
    for i=1:numframes(j)
        if mod(i,1000)==1
            j
            i
        end
        chone(:,:,i)=imread(fullfilename,'tiff',i,'Info',info);
    end

    %scale movie for seamless intensities
    if j==1
        meanlastframes=median(mean(mean(chone(:,:,1:400))));
    end

    meanfirstframes=median(mean(mean(chone(:,:,1:400))));
    chone=chone*(meanlastframes/meanfirstframes);
    meanlastframes=median(mean(mean(chone(:,:,end-400:end))));
    
    %Construct Movie Segments
    segPos = [];
    xind = floor(linspace(1,M/2,3));
    yind = floor(linspace(1,N/2,3));
    for x=1:length(xind)
        for y=1:length(yind)
            segPos(end+1,:) = [xind(x) yind(y)  M/2 N/2];
        end
    end
    nSeg = size(segPos,1);
    
    %First order motion correction
    clear xshifts yshifts corThresh,
    for Seg = 1:nSeg
        Seg,
        tMov = chone(segPos(Seg,2):segPos(Seg,2)+segPos(Seg,4),segPos(Seg,1):segPos(Seg,1)+segPos(Seg,3),:);
         tBase = prctile(tMov(:),20);
         tTop = prctile(tMov(:),80);
         tMov = (tMov - tBase) / (tTop-tBase);
         tMov(tMov<0) = 0; tMov(tMov>1) = 1;
    [xshifts(Seg,:),yshifts(Seg,:)]=track_subpixel_wholeframe_motion_varythresh(...
        tMov,median(tMov,3),5,0.95,75);
    end
    
    choneWins = AcquisitionCorrect(chone,mean(xshifts),mean(yshifts));
       
    cated_movie=cat(3,cated_movie,chone);
    cated_xShift = cat(2,cated_xShift, xshifts);
    cated_yShift = cat(2,cated_yShift, yshifts);
    acqRef = cat(3,acqRef,median(choneWins(6:end-5,6:end-5,:),3));
end

clear info chone choneWins

[xshiftsAcq,yshiftsAcq]=track_subpixel_wholeframe_motion_varythresh(acqRef,acqRef(:,:,ceil(num_files/2)),10,0.99,100);
for j=1:num_files
    ind = sum(numframes(1:j-1)) + (1:numframes(j));
    xshiftAcq(ind) = xshiftsAcq(j);
    yshiftAcq(ind) = yshiftsAcq(j);
end


xshift = -(cated_xShift + repmat(xshiftAcq,nSeg,1));
yshift = -(cated_yShift + repmat(yshiftAcq,nSeg,1));
usePos = 1:nSeg;
yoff = segPos(usePos,2) + floor(segPos(usePos,4)/2);
xoff = segPos(usePos,1) + floor(segPos(usePos,3)/2);
rpts = [xoff, yoff];
R=imref2d([N,M]);

for frame = 2:size(cated_movie,3)
    if mod(frame,250)==1
        frame
    end
    xframe = xshift(usePos,frame) + xoff;
    yframe = yshift(usePos,frame) + yoff;
    fpts = [xframe, yframe];
    tform=fitgeotrans(fpts,rpts,'affine');
    cated_movie(:,:,frame)=imwarp(cated_movie(:,:,frame),tform,'OutputView',R);   
end

cated_movie(:,:,1) = cated_movie(:,:,2);

blank=sum(cated_movie==0,3);
xmin=find(median(blank,1)==0,1,'first'),
xmax=find(median(blank,1)==0,1,'last'),
ymin=find(median(blank,2)==0,1,'first'),
ymax=find(median(blank,2)==0,1,'last'),
cated_movie=cated_movie(ymin:ymax,xmin:xmax,:);
save(cated_tiff_filename,'cated_movie','-v7.3')


%% Calculate piecewise covariance, principle components, and feed to ICA algorithm

M=size(cated_movie,1);
N=size(cated_movie,2);
Z=size(cated_movie,3);
nPCs = 500;
cated_movie=reshape(cated_movie,M*N,size(cated_movie,3));

AcqCov = zeros(M*N,M*N);
for j=1:num_files
    j,
ind = sum(numframes(1:j-1)) + (2:numframes(j));
AcqCov = AcqCov + cov(double(cated_movie(:,ind)'));
end
AcqCov = AcqCov / num_files;

[V,D] = eig(AcqCov);
D=diag(D);
V=fliplr(V);
D=flipud(D);
clear AcqCov
covtrace = sum(D);
CovEvals = D(1:nPCs);
clear D;
mixedsig = V(:,1:nPCs)' * double(cated_movie);
mixedfilters = reshape(V(:,1:nPCs),M,N,nPCs);
save(sprintf('%s_PCs',cated_tiff_filename),'mixedsig','mixedfilters','covtrace','CovEvals')


PCuse = 1:300;
mu=.2;
nIC = ceil(length(PCuse)/2);
ica_A_guess = [];
termtol = 1e-6;
maxrounds = 1e3;
smwidth = 3;
thresh = 2;
arealims = [20 400];
plotting = 1;
[ica_sig, ica_filters, ica_A, numiter] = CellsortICA(...
     mixedsig,mixedfilters, CovEvals, PCuse, mu, nIC, ica_A_guess, termtol, maxrounds);
[ica_segments, segmentlabel, segcentroid] = CellsortSegmentation...
    (ica_filters, smwidth, thresh, arealims, plotting);
for i=1:size(ica_segments,1)
    normSeg(:,:,i)=100*ica_segments(i,:,:)/norm(reshape(ica_segments(i,:,:),1,[]));
end
normSeg = reshape(normSeg,M*N,[]);
SegTraces = normSeg' * cated_movie;
normSeg = reshape(normSeg,M,N,[]);

for i=1:size(ica_segments,1)
    segSize(i) = squeeze(sum(sum(ica_segments(i,:,:)>0)));
    segSkew(i) = skewness(reshape(ica_segments(i,:,:),1,[]));
end
segSTD = sqrt(std(SegTraces,[],2)./mean(SegTraces,2));
segSize = zscore(segSize);
segSkew = zscore(segSkew);

goodSeg = find(segSize-segSkew > 0);
gTrace = SegTraces(goodSeg,:);
save(sprintf('%s_ICs',cated_tiff_filename),...
    'SegTraces','normSeg','ica_sig','ica_filters','ica_A','ica_segments','segmentlabel','segcentroid',...
    'segSize','segSkew','segSTD','goodSeg','gTrace')
figure,scatter(segSize,segSkew,50,segSTD,'filled')