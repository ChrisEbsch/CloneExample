/**
 * @file SimulationDomainGPU.cu
 * @brief this file contains domain level logic.
 * @author Wenzhao Sun wsun2@nd.edu
 * @bug no know bugs
 */

#include "SimulationDomainGPU.h"

using namespace std;

// #define DebugModeDomain

/**
 * Constructor.
 * reads values from config file.
 */
SimulationDomainGPU::SimulationDomainGPU() {
	readAllParameters();
	if (memPara.simuType == Beak) {
		initializeGrowthMap();
	}
}

void SimulationDomainGPU::initializeNodes(CartPara &cartPara,
		std::vector<SceNodeType>& cellTypes,
		std::vector<uint>& numOfInitActiveNodesOfCells,
		std::vector<CVector>& initBdryNodeVec,
		std::vector<CVector>& initProfileNodeVec,
		std::vector<CVector>& initCartNodeVec,
		std::vector<CVector>& initECMNodeVec,
		std::vector<CVector>& initFNMNodeVec,
		std::vector<CVector>& initMXNodeVec) {

	/*
	 * number of boundary nodes is always fixed.
	 */
	uint bdryNodeCount = initBdryNodeVec.size();
	/*
	 * total potential number of profile nodes could be more than initial number provided,
	 * because the total length of profile might increase.
	 * FinalToInitProfileNodeCountRatio is defined in Config file.
	 */
	uint maxProfileNodeCount = initProfileNodeVec.size()
			* memPara.FinalToInitProfileNodeCountRatio;

	/**
	 * different from profile nodes, the cartilage nodes should already
	 * have buffer before executing this method.
	 */
	uint maxCartNodeCount = initCartNodeVec.size();

	/*
	 * Initialize SceNodes by constructor. first two parameters come from input parameters
	 * while the last four parameters come from Config file.
	 */
	nodes = SceNodes(bdryNodeCount, maxProfileNodeCount, maxCartNodeCount,
			memPara.maxECMInDomain, memPara.maxNodePerECM,
			memPara.maxCellInDomain, memPara.maxNodePerCell, memPara.isStab);

	//cartilage.distributeIsActive();
	//cartilage.initializeNodes(initCartNodeVec);

	/*
	 * first step: error checking.
	 * we need to first check if inputs are valid
	 */
	// get max node per cell. should be defined previously.
	uint maxNodePerCell = nodes.getAllocPara().maxNodeOfOneCell;
	// get max node per ECM. Should be defined previously.
	uint maxNodePerECM = nodes.getAllocPara().maxNodePerECM;
	// check if we successfully loaded maxNodePerCell
	assert(maxNodePerCell != 0);

	// obtain sizes of the input arrays
	//uint bdryNodeCount = initBdryNodeVec.size();
	uint ProfileNodeCount = initProfileNodeVec.size();
	uint CartNodeCount = initCartNodeVec.size();
	uint ECMNodeCount = initECMNodeVec.size();
	uint FNMNodeCount = initFNMNodeVec.size();
	uint MXNodeCount = initMXNodeVec.size();

	// array size of cell type array
	uint cellTypeSize = cellTypes.size();
	// array size of initial active node count of cells array.
	uint initNodeCountSize = numOfInitActiveNodesOfCells.size();
	// two sizes must match.
	assert(cellTypeSize == initNodeCountSize);

	// size of inputs must be divided exactly by max node per cell.
	// uint bdryRemainder = bdryNodeCountX % maxNodePerCell;
	uint ecmRemainder = 0;
	uint ecmQuotient = 0;
	if (memPara.simuType == Beak) {
		ecmQuotient = ECMNodeCount / maxNodePerECM;
		ecmRemainder = ECMNodeCount % maxNodePerECM;
	}
	uint fnmRemainder = FNMNodeCount % maxNodePerCell;
	uint mxRemainder = MXNodeCount % maxNodePerCell;

	// uint bdryQuotient = bdryNodeCountX / maxNodePerCell;
	uint fnmQuotient = FNMNodeCount / maxNodePerCell;
	uint mxQuotient = MXNodeCount / maxNodePerCell;

	// remainder must be zero.
	if ((fnmRemainder != 0) || (mxRemainder != 0) || (ecmRemainder != 0)) {
		throw SceException("Initialization vector size incorrect!",
				InputInitException);
	}
	// size of cellType array and sum of all cell types must match.
	assert(fnmQuotient + mxQuotient == cellTypeSize);

	for (uint i = 0; i < cellTypeSize; i++) {
		if (i < fnmQuotient) {
			assert(cellTypes[i] == FNM);
		} else {
			assert(cellTypes[i] == MX);
		}
	}
	/*
	 * second part: actual initialization
	 * copy data from main system memory to GPU memory
	 */
	NodeAllocPara para = nodes.getAllocPara();
	para.currentActiveCellCount = fnmQuotient + mxQuotient;
	para.currentActiveECM = ecmQuotient;
	para.currentActiveProfileNodeCount = ProfileNodeCount;
	nodes.setAllocPara(para);

	assert(nodes.getAllocPara().startPosProfile == bdryNodeCount);

	nodes.initValues(initBdryNodeVec, initProfileNodeVec, initCartNodeVec,
			initECMNodeVec, initFNMNodeVec, initMXNodeVec);

	/**
	 * setting the cartilage related parameters in the simulation domain.
	 */
	if (memPara.simuType == Beak && !memPara.isStab) {
		cartilage.setCartPara(cartPara);
		cartilage.initializeMem(&nodes);
	}

	cells = SceCells(&nodes, numOfInitActiveNodesOfCells, cellTypes);
}

void SimulationDomainGPU::initializeNodes_M(std::vector<SceNodeType> &nodeTypes,
		std::vector<bool> &nodeIsActive, std::vector<CVector> &initNodesVec,
		std::vector<uint> &initActiveMembrNodeCounts,
		std::vector<uint> &initActiveIntnlNodeCounts,
		std::vector<double> &initGrowProgVec) {
	/*
	 * Initialize SceNodes by constructor. first two parameters come from input parameters
	 * while the last four parameters come from Config file.
	 */
	std::cout << "Initializing nodes ...... " << std::endl;
	nodes = SceNodes(memPara.maxCellInDomain, memPara.maxAllNodePerCell);

	//std::cout << "break point 1 " << std::endl;
	//std::cout.flush();
	// array size of cell type array
	uint nodeTypeSize = nodeTypes.size();
	// array size of initial active node count of cells array.
	uint initMembrNodeCountSize = initActiveMembrNodeCounts.size();
	uint initIntnlNodeCountSize = initActiveIntnlNodeCounts.size();
	// two sizes must match.
	assert(initMembrNodeCountSize == initIntnlNodeCountSize);
	assert(
			memPara.maxCellInDomain * memPara.maxAllNodePerCell
					== nodeTypes.size());

	//std::cout << "break point 2 " << std::endl;
	//std::cout.flush();
	/*
	 * second part: actual initialization
	 * copy data from main system memory to GPU memory
	 */
	NodeAllocPara_M para = nodes.getAllocParaM();
	para.currentActiveCellCount = initMembrNodeCountSize;
	assert(
			initNodesVec.size() / para.maxAllNodePerCell
					== initMembrNodeCountSize);
	nodes.setAllocParaM(para);

	//std::cout << "break point 3 " << std::endl;
	//std::cout.flush();

	nodes.initValues_M(nodeIsActive, initNodesVec, nodeTypes);

	//std::cout << "break point 4 " << std::endl;
	//std::cout.flush();

	//for (uint i = 0; i < initActiveMembrNodeCounts.size(); i++) {
	//	std::cout << " (" << initActiveMembrNodeCounts[i] << ", "
	//			<< initActiveIntnlNodeCounts[i] << ") ";
	//}
	//std::cout << std::endl;
	cells = SceCells(&nodes, initActiveMembrNodeCounts,
			initActiveIntnlNodeCounts, initGrowProgVec);

	//std::cout << "break point 5 " << std::endl;
	//std::cout.flush();
}

void SimulationDomainGPU::initialize_v2(SimulationInitData_V2& initData) {
	std::cout << "begin initialization process" << std::endl;
	memPara.isStab = initData.isStab;
	initializeNodes(initData.cartPara, initData.cellTypes,
			initData.numOfInitActiveNodesOfCells, initData.initBdryNodeVec,
			initData.initProfileNodeVec, initData.initCartNodeVec,
			initData.initECMNodeVec, initData.initFNMNodeVec,
			initData.initMXNodeVec);
	std::cout << "finished init simulation domain nodes" << std::endl;
	nodes.initDimension(domainPara.minX, domainPara.maxX, domainPara.minY,
			domainPara.maxY, domainPara.gridSpacing);
	std::cout << "finished init nodes dimension" << std::endl;
	// The domain task is not stabilization unless specified in the next steps.
	stabPara.isProcessStab = false;
}

void SimulationDomainGPU::initialize_v2_M(SimulationInitData_V2_M& initData) {
	std::cout << "Start initializing simulation domain ......" << std::endl;
	memPara.isStab = initData.isStab;
	initializeNodes_M(initData.nodeTypes, initData.initIsActive,
			initData.initNodeVec, initData.initActiveMembrNodeCounts,
			initData.initActiveIntnlNodeCounts, initData.initGrowProgVec);
	std::cout << "Finished initializing nodes positions" << std::endl;
	nodes.initDimension(domainPara.minX, domainPara.maxX, domainPara.minY,
			domainPara.maxY, domainPara.gridSpacing);
	//std::cout << "finished init nodes dimension" << std::endl;
	// The domain task is not stabilization unless specified in the next steps.
	stabPara.isProcessStab = false;
	std::cout << "Finished initializing simulation domain" << std::endl;
}

/**
 * Highest level logic of domain.
 *
 */
void SimulationDomainGPU::runAllLogic(double dt) {
	if (memPara.simuType == Beak && !stabPara.isProcessStab) {
		nodes.processCartGrowthDir(cartilage.getCartPara().growthDir);
	}

	if (memPara.simuType == Beak) {
		nodes.calculateAndApplySceForces();
	} else if (memPara.simuType == Disc) {
		nodes.sceForcesDisc();
	}

	// This function only calculates velocity.

	// Only beak simulation need to take care of cartilage.
	if (memPara.simuType == Beak && !stabPara.isProcessStab) {
		// cartilage logics must come before cell logics, because node velocities will be modified
		// in cell logic and consequently we won't be able to compute cartilage data.
		// also responsible for handling interaction between epithelium layer and carilage.
		cartilage.runAllLogics(dt);
	}

	// This function applies velocity so nodes actually move inside this function.
	if (memPara.simuType == Beak) {
		cells.runAllCellLevelLogicsBeak(dt, growthMap, growthMap2);
	} else if (memPara.simuType == Disc) {
		cells.runAllCellLevelLogicsDisc(dt);
	}

	if (memPara.simuType == SingleCellTest) {
		nodes.sceForcesDisc();
		cells.runStretchTest(dt);
	}
}

void SimulationDomainGPU::runAllLogic_M(double dt) {
#ifdef DebugModeDomain
	cudaEvent_t start1, start2, stop;
	float elapsedTime1, elapsedTime2;
	cudaEventCreate(&start1);
	cudaEventCreate(&start2);
	cudaEventCreate(&stop);
	cudaEventRecord(start1, 0);
#endif

	nodes.sceForcesDisc_M();

#ifdef DebugModeDomain
	cudaEventRecord(start2, 0);
	cudaEventSynchronize(start2);
	cudaEventElapsedTime(&elapsedTime1, start1, start2);
#endif

	cells.runAllCellLogicsDisc_M(dt);

#ifdef DebugModeDomain
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&elapsedTime2, start2, stop);
	std::cout << "time spent in Simu Domain logic: " << elapsedTime1 << " "
	<< elapsedTime2 << std::endl;
#endif
}

void SimulationDomainGPU::readMemPara() {
	int simuTypeConfigValue =
			globalConfigVars.getConfigValue("SimulationType").toInt();

	memPara.simuType = parseTypeFromConfig(simuTypeConfigValue);

	memPara.maxCellInDomain =
			globalConfigVars.getConfigValue("MaxCellInDomain").toInt();
	if (memPara.simuType != Disc_M) {
		memPara.maxNodePerCell = globalConfigVars.getConfigValue(
				"MaxNodePerCell").toInt();
	}

	if (memPara.simuType == Beak) {
		memPara.maxECMInDomain = globalConfigVars.getConfigValue(
				"MaxECMInDomain").toInt();
		memPara.maxNodePerECM =
				globalConfigVars.getConfigValue("MaxNodePerECM").toInt();
		memPara.FinalToInitProfileNodeCountRatio =
				globalConfigVars.getConfigValue(
						"FinalToInitProfileNodeCountRatio").toDouble();
	} else {
		memPara.maxECMInDomain = 0;
		memPara.maxNodePerECM = 0;
		memPara.FinalToInitProfileNodeCountRatio = 0;
	}

	if (memPara.simuType == Disc_M) {
		memPara.maxMembrNodePerCell = globalConfigVars.getConfigValue(
				"MaxMembrNodeCountPerCell").toInt();
		memPara.maxIntnlNodePerCell = globalConfigVars.getConfigValue(
				"MaxIntnlNodeCountPerCell").toInt();
		memPara.maxAllNodePerCell = globalConfigVars.getConfigValue(
				"MaxAllNodeCountPerCell").toInt();
		assert(
				memPara.maxMembrNodePerCell + memPara.maxIntnlNodePerCell
						== memPara.maxAllNodePerCell);
	}
}

void SimulationDomainGPU::readDomainPara() {
	domainPara.minX = globalConfigVars.getConfigValue("DOMAIN_XMIN").toDouble();
	domainPara.maxX = globalConfigVars.getConfigValue("DOMAIN_XMAX").toDouble();
	domainPara.minY = globalConfigVars.getConfigValue("DOMAIN_YMIN").toDouble();
	domainPara.maxY = globalConfigVars.getConfigValue("DOMAIN_YMAX").toDouble();
	domainPara.minZ = globalConfigVars.getConfigValue("DOMAIN_ZMIN").toDouble();
	domainPara.maxZ = globalConfigVars.getConfigValue("DOMAIN_ZMAX").toDouble();
	domainPara.gridSpacing = nodes.getMaxEffectiveRange();
	domainPara.numOfBucketsInXDim = (domainPara.maxX - domainPara.minX)
			/ domainPara.gridSpacing + 1;
	domainPara.numOfBucketsInYDim = (domainPara.maxY - domainPara.minY)
			/ domainPara.gridSpacing + 1;
}

void SimulationDomainGPU::readChemPara() {
	chemPara.growthGridXDim =
			globalConfigVars.getConfigValue("GrowthGridXDim").toInt();
	chemPara.growthGridYDim =
			globalConfigVars.getConfigValue("GrowthGridYDim").toInt();
	chemPara.growthGridSpacing = globalConfigVars.getConfigValue(
			"GrowthGridSpacing").toDouble();
	chemPara.growthGridLowerLeftPtX = globalConfigVars.getConfigValue(
			"GrowthGridLowerLeftPtX").toDouble();
	chemPara.growthGridLowerLeftPtY = globalConfigVars.getConfigValue(
			"GrowthGridLowerLeftPtY").toDouble();

	chemPara.growthMorCenterXCoord = globalConfigVars.getConfigValue(
			"GrowthMorCenterXCoord").toDouble();
	chemPara.growthMorCenterYCoord = globalConfigVars.getConfigValue(
			"GrowthMorCenterYCoord").toDouble();
	chemPara.growthMorHighConcen = globalConfigVars.getConfigValue(
			"GrowthMorHighConcen").toDouble();
	chemPara.growthMorLowConcen = globalConfigVars.getConfigValue(
			"GrowthMorLowConcen").toDouble();
	chemPara.growthMorDiffSlope = globalConfigVars.getConfigValue(
			"GrowthMorDiffSlope").toDouble();

	chemPara.growthMorCenterXCoordMX = globalConfigVars.getConfigValue(
			"GrowthMorCenterXCoordMX").toDouble();
	chemPara.growthMorCenterYCoordMX = globalConfigVars.getConfigValue(
			"GrowthMorCenterYCoordMX").toDouble();
	chemPara.growthMorHighConcenMX = globalConfigVars.getConfigValue(
			"GrowthMorHighConcenMX").toDouble();
	chemPara.growthMorLowConcenMX = globalConfigVars.getConfigValue(
			"GrowthMorLowConcenMX").toDouble();
	chemPara.growthMorDiffSlopeMX = globalConfigVars.getConfigValue(
			"GrowthMorDiffSlopeMX").toDouble();
}

void SimulationDomainGPU::readAllParameters() {
	readMemPara();
	readDomainPara();
	if (memPara.simuType == Beak) {
		readChemPara();
	}
}

void SimulationDomainGPU::initializeGrowthMap() {
	growthMap = GrowthDistriMap(chemPara.growthGridXDim,
			chemPara.growthGridYDim, chemPara.growthGridSpacing);
	growthMap.initialize(chemPara.growthGridLowerLeftPtX,
			chemPara.growthGridLowerLeftPtY, chemPara.growthMorCenterXCoord,
			chemPara.growthMorCenterYCoord, chemPara.growthMorHighConcen,
			chemPara.growthMorLowConcen, chemPara.growthMorDiffSlope);

	//cout << "after created growthMap1" << endl;
	growthMap2 = GrowthDistriMap(chemPara.growthGridXDim,
			chemPara.growthGridYDim, chemPara.growthGridSpacing);
	growthMap2.initialize(chemPara.growthGridLowerLeftPtX,
			chemPara.growthGridLowerLeftPtY, chemPara.growthMorCenterXCoordMX,
			chemPara.growthMorCenterYCoordMX, chemPara.growthMorHighConcenMX,
			chemPara.growthMorLowConcenMX, chemPara.growthMorDiffSlopeMX);
	//cout << "after created growthMap2" << endl;
}

std::vector<CVector> SimulationDomainGPU::stablizeCellCenters(
		SimulationInitData_V2 &initData) {

	std::vector<CVector> result;

	stabPara.outputFrameCount = globalConfigVars.getConfigValue(
			"StabFrameCount").toInt();
	stabPara.totalIterCount = globalConfigVars.getConfigValue(
			"StabTotalIterCount").toInt();
	stabPara.bdrySpacingRatio = globalConfigVars.getConfigValue(
			"StabBdrySpacingRatio").toDouble();
	stabPara.dt = globalConfigVars.getConfigValue("StabDt").toDouble();
	stabPara.outputAniName =
			globalConfigVars.getConfigValue("StabAniName").toString();

	initialize_v2(initData);
	stabPara.isProcessStab = true;
	int aniAuxPara;
	if (stabPara.outputFrameCount == 0) {
		aniAuxPara = INT_MAX;
	} else {
		aniAuxPara = (double) (stabPara.totalIterCount)
				/ stabPara.outputFrameCount;
	}

	AnimationCriteria aniCri;
	aniCri.defaultEffectiveDistance = globalConfigVars.getConfigValue(
			"IntraLinkDisplayRange").toDouble();
	int configAniType =
			globalConfigVars.getConfigValue("AnimationType").toInt();
	aniCri.animationType = CellType;

	uint index = 0;
	for (int i = 0; i < stabPara.totalIterCount; i++) {
		//std::cout << "in stablizing, before run all logics" << std::endl;
		if (i % aniAuxPara == 0) {
			outputVtkFilesWithCri(stabPara.outputAniName, index, aniCri);
			index++;
		}
		runAllLogic(stabPara.dt);
	}

	result = cells.getAllCellCenters();

	cout << "finished stablizeCellCenters" << endl;
	cout.flush();
	return result;
}

void SimulationDomainGPU::outputVtkFilesWithCri(std::string scriptNameBase,
		int rank, AnimationCriteria aniCri) {
	nodes.prepareSceForceComputation();
	VtkAnimationData aniData = nodes.obtainAnimationData(aniCri);
	aniData.outputVtkAni(scriptNameBase, rank);
}

void SimulationDomainGPU::outputVtkFilesWithCri_M(std::string scriptNameBase,
		int rank, AnimationCriteria aniCri) {
	nodes.prepareSceForceComputation();
	//std::cout << "started generate raw data" << std::endl;
	AniRawData rawAni = cells.obtainAniRawData(aniCri);
	//std::cout << "finished generate raw data" << std::endl;
	VtkAnimationData aniData = cells.outputVtkData(rawAni, aniCri);
	//std::cout << "finished generate vtk data" << std::endl;
	aniData.outputVtkAni(scriptNameBase, rank);
	//std::cout << "finished generate vtk file" << std::endl;
}

void SimulationDomainGPU::outputVtkGivenCellColor(std::string scriptNameBase,
		int rank, AnimationCriteria aniCri, std::vector<double>& cellColorVal) {
	nodes.prepareSceForceComputation();
	AniRawData rawAni = cells.obtainAniRawDataGivenCellColor(cellColorVal,
			aniCri);
	VtkAnimationData aniData = cells.outputVtkData(rawAni, aniCri);
	aniData.outputVtkAni(scriptNameBase, rank);
}

void SimulationDomainGPU::outputVtkColorByCell(std::string scriptNameBase,
		int rank, AnimationCriteria aniCri) {
	assert(aniCri.animationType == T1Tran);
	std::vector<double> t1ColorVec = processT1Color();
	outputVtkGivenCellColor(scriptNameBase, rank, aniCri, t1ColorVec);
}

std::vector<double> SimulationDomainGPU::processT1Color() {
	std::vector<double> result;
	result.resize(cells.getAllocParaM().currentActiveCellCount);
	for (int i = 0; i < int(result.size()); i++) {
		if (t1CellSet.find(i) == t1CellSet.end()) {
			result[i] = 0;
		} else {
			result[i] = 1;
		}
	}
	return result;
}

void SimulationDomainGPU::printDomainInformation() {
	cout << "Begin output information about nodes:" << endl;
	cout << "size of isActive:" << nodes.getInfoVecs().nodeIsActive.size()
			<< endl;
	cout << "size of nodeLocX:" << nodes.getInfoVecs().nodeLocX.size() << endl;
	cout << "size of nodeLocY:" << nodes.getInfoVecs().nodeLocY.size() << endl;
	cout << "size of nodeLocZ:" << nodes.getInfoVecs().nodeLocZ.size() << endl;
	cout << "size of nodeVelX:" << nodes.getInfoVecs().nodeVelX.size() << endl;
	cout << "size of nodeVelY:" << nodes.getInfoVecs().nodeVelY.size() << endl;
	cout << "size of nodeVelZ:" << nodes.getInfoVecs().nodeVelZ.size() << endl;
	cout << "size of CellType:" << nodes.getInfoVecs().nodeCellType.size()
			<< endl;
	cout << "size of nodeCellRank:" << nodes.getInfoVecs().nodeCellRank.size()
			<< endl;

	cout << "start position of Profile is "
			<< nodes.getAllocPara().startPosProfile << endl;
	cout << "start position of ECM is " << nodes.getAllocPara().startPosECM
			<< endl;
	cout << "start position of Cells is " << nodes.getAllocPara().startPosCells
			<< endl;

	cout << "max node of one cell is " << nodes.getAllocPara().maxNodeOfOneCell
			<< endl;
	cout << "max number of cells is " << nodes.getAllocPara().maxCellCount
			<< endl;
	cout << "max total cell node count is "
			<< nodes.getAllocPara().maxTotalCellNodeCount << endl;
	cout << "current active cell count is "
			<< nodes.getAllocPara().currentActiveCellCount << endl;

	cout << "max node of one ECM is " << nodes.getAllocPara().maxNodePerECM
			<< endl;
	cout << "max number of ECm is " << nodes.getAllocPara().maxECMCount << endl;
	cout << "max total ECM node count is "
			<< nodes.getAllocPara().maxTotalECMNodeCount << endl;
	cout << "current active ECM count is "
			<< nodes.getAllocPara().currentActiveECM << endl;

	cout << "max profile node count is "
			<< nodes.getAllocPara().maxProfileNodeCount << endl;
	cout << "current active profile node count is "
			<< nodes.getAllocPara().currentActiveProfileNodeCount << endl;
}

vector<vector<int> > SimulationDomainGPU::outputLabelMatrix(
		std::string resultNameBase, int rank, PixelizePara& pixelPara) {
	std::stringstream ss;
	ss << std::setw(5) << std::setfill('0') << rank;
	std::string resultNameRank = ss.str();
	std::string matrixFileName = resultNameBase + resultNameRank + ".dat";
	vector<vector<int> > matrix = nodes.obtainLabelMatrix(pixelPara);
	printMatrixToFile(matrix, matrixFileName);
	return matrix;
}

void SimulationDomainGPU::outputGrowthProgressAuxFile(int step) {
	static bool isFirstTime = true;
	std::string auxDataFileName = globalConfigVars.getConfigValue(
			"DataOutputFolder").toString()
			+ globalConfigVars.getConfigValue("GrowthAuxFileName").toString();
	if (isFirstTime) {
		std::remove(auxDataFileName.c_str());
		isFirstTime = false;
	}
	std::cout << "Updating growth progress file" << std::endl;
	ofstream ofs;
	ofs.open(auxDataFileName.c_str(), ios::app);
	ofs << step << " ";
	std::vector<double> growProVec = cells.getGrowthProgressVec();
	for (std::vector<double>::iterator it = growProVec.begin();
			it != growProVec.end(); ++it) {
		ofs << *it << " ";
	}
	ofs << std::endl;
	ofs.close();
}

void SimulationDomainGPU::analyzeLabelMatrix(vector<vector<int> > &labelMatrix,
		int step, std::string &imageFileNameBase, std::string &statFileName) {
	ResAnalysisHelper resHelper;

	std::stringstream ss;
	ss << std::setw(5) << std::setfill('0') << step;
	std::string imgNameRank = ss.str();
	std::string imgFileName = imageFileNameBase + imgNameRank + ".bmp";

	resHelper.outputImg_formatBMP(imgFileName, labelMatrix);
	std::vector<double> growthProVec = cells.getGrowthProgressVec();
	if (memPara.simuType == Disc) {
		resHelper.outputStat_PolygonCounting(statFileName, step, labelMatrix,
				growthProVec);
		outputGrowthProgressAuxFile(step);
	} else {
		resHelper.outputStat_PolygonCounting(statFileName, step, labelMatrix);
	}
}

bool SimulationDomainGPU::isDividing_ForAni() {
	if (cells.aniDebug) {
		cells.aniDebug = false;
		return true;
	}
	return false;
}

void SimulationDomainGPU::performAblation(AblationEvent& ablEvent) {
	thrust::host_vector<double> xCoord = nodes.getInfoVecs().nodeLocX;
	thrust::host_vector<double> yCoord = nodes.getInfoVecs().nodeLocY;

	AblationEvent aa;

	for (uint i = 0; i < xCoord.size(); i++) {
		double xDiff = xCoord[i] - 25.3;
		double yDiff = yCoord[i] - 25.2;
		if (xDiff * xDiff + yDiff * yDiff < 0.04) {
			uint cellRank = i / 90;
			uint nodeRank = i % 90;
			std::cout << "cell : " << cellRank << ", node: " << nodeRank
					<< "pos: (" << xCoord[i] << "," << yCoord[i] << ")"
					<< std::endl;
			bool found = false;
			for (uint j = 0; j < aa.ablationCells.size(); j++) {
				if (aa.ablationCells[j].cellNum == cellRank) {
					found = true;
					aa.ablationCells[j].nodeNums.push_back(nodeRank);
				}
			}
			if (!found) {
				AblaInfo cellNew;
				cellNew.cellNum = cellRank;
				cellNew.nodeNums.push_back(nodeRank);
				aa.ablationCells.push_back(cellNew);
			}
		}
	}

	aa.printInfo();
	int jj;
	cin >> jj;

	cells.runAblationTest(aa);
}

CellsStatsData SimulationDomainGPU::outputPolyCountData() {
	// this step is necessary for obtaining correct neighbors because new cells might have been created in previous step.
	nodes.sceForcesDisc_M();
	return cells.outputPolyCountData();
}

NetworkInfo SimulationDomainGPU::buildNetInfo(CellsStatsData &polyData) {
	std::vector<NetworkNode> netNodes;
	for (uint i = 0; i < polyData.cellsStats.size(); i++) {
		NetworkNode netNode;
		netNode.setGrowP(polyData.cellsStats[i].cellGrowthProgress);
		netNode.setNodeRank(polyData.cellsStats[i].cellRank);
		netNode.setPos(polyData.cellsStats[i].cellCenter);
		std::vector<int> ngbrVec(polyData.cellsStats[i].neighborVec.begin(),
				polyData.cellsStats[i].neighborVec.end());
		netNode.setNgbrList(ngbrVec);
		netNodes.push_back(netNode);
	}
	NetworkInfo result(netNodes);
	return result;
}

std::set<int> SimulationDomainGPU::findT1Transition() {
	std::set<int> result;
	for (uint i = 0; i < preT1Vec.size(); i++) {
		for (uint j = 0; j < preT1Vec[i].size(); j++) {
			if (netInfo.isT1Tran(preT1Vec[i][j])) {
				result.insert(preT1Vec[i][j].nodeRank);
				result.insert(preT1Vec[i][j].centerNgbr);
				result.insert(preT1Vec[i][j].sideNgbrs[0]);
				result.insert(preT1Vec[i][j].sideNgbrs[1]);
			}
		}
	}
	if (result.size() != 0) {
		std::cout << "found T1 transition!" << std::endl;
	}
	return result;
}

void SimulationDomainGPU::processT1Info(int maxStepTraceBack,
		CellsStatsData &polyData) {
	// first, construct network info
	netInfo = buildNetInfo(polyData);

	// second, find all of the previous pre-t1 states matches
	// has make t1 transition under current network info. output
	// these cell numbers.
	//t1CellSet = findT1Transition();

	// finally, update the pre-T1 info vector by remove old one
	// and add new one.
	if (preT1Vec.size() >= maxStepTraceBack) {
		int eraseSize = preT1Vec.size() - maxStepTraceBack + 1;
		preT1Vec.erase(preT1Vec.begin(), preT1Vec.begin() + eraseSize);
	}
	std::vector<PreT1State> preT1States = netInfo.scanForPreT1States();
	preT1Vec.push_back(preT1States);
}
