--[[
Title: Block Model
Author(s): LiXizhi
Date: 2015/5/25
Desc: 
use the lib:
------------------------------------------------------------
NPL.load("(gl)script/apps/Aries/Creator/Game/Entity/EntityBlockModel.lua");
local EntityBlockModel = commonlib.gettable("MyCompany.Aries.Game.EntityManager.EntityBlockModel")
-------------------------------------------------------
]]
NPL.load("(gl)script/apps/Aries/Creator/Game/Entity/EntityBlockBase.lua");
local Files = commonlib.gettable("MyCompany.Aries.Game.Common.Files");
local Direction = commonlib.gettable("MyCompany.Aries.Game.Common.Direction")
local BlockEngine = commonlib.gettable("MyCompany.Aries.Game.BlockEngine")
local block_types = commonlib.gettable("MyCompany.Aries.Game.block_types")
local GameLogic = commonlib.gettable("MyCompany.Aries.Game.GameLogic")
local EntityManager = commonlib.gettable("MyCompany.Aries.Game.EntityManager");
local Packets = commonlib.gettable("MyCompany.Aries.Game.Network.Packets");

local Entity = commonlib.inherit(commonlib.gettable("MyCompany.Aries.Game.EntityManager.EntityBlockBase"), commonlib.gettable("MyCompany.Aries.Game.EntityManager.EntityBlockModel"));

Entity:Property({"scale", 1, "getScale", "setScale"});
Entity:Property({"yaw", 0, "getYaw", "setYaw"});

-- class name
Entity.class_name = "EntityBlockModel";
EntityManager.RegisterEntityClass(Entity.class_name, Entity);
Entity.is_persistent = true;
-- always serialize to 512*512 regional entity file
Entity.is_regional = true;
-- if model is invalid, use this model file. 
Entity.default_file = "character/common/headquest/headquest.x";

function Entity:ctor()
end

function Entity:init()
	if(not Entity._super.init(self)) then
		return
	end
	local block_template = block_types.get(self:GetBlockId());
	if(block_template) then
		self.useRealPhysics = not block_template.obstruction;
	end
	self:CreateInnerObject(self.filename, self.scale);
	return self;
end

-- we will use C++ polygon-level physics engine for real physics. 
function Entity:HasRealPhysics()
	return self.useRealPhysics;
end

-- @param filename: if nil, self.filename is used
function Entity:GetModelDiskFilePath(filename)
	return Files.GetFilePath(filename or self:GetModelFile());
end

-- this is helper function that derived class can use to create an inner mesh or character object. 
function Entity:CreateInnerObject(filename, scale)
	filename = Files.GetFilePath(self:GetModelDiskFilePath(filename)) or self.default_file;
	local x, y, z = self:GetPosition();

	if(filename == self.default_file) then
		if(self.filename and self.filename~="") then
			-- TODO: fetch from remote server?
			LOG.std(nil, "warn", "EntityBlockModel", "filename: %s not found at %d %d %d", self.filename or "", self.bx or 0, self.by or 0, self.bz or 0);	
		end
	end

	local model = ParaScene.CreateObject("BMaxObject", self:GetBlockEntityName(), x,y,z);
	model:SetField("assetfile", filename);
	if(self.scale) then
		model:SetScaling(self.scale);
	end
	if(self.facing) then
		model:SetFacing(self.facing);
	end
	-- OBJ_SKIP_PICKING = 0x1<<15:
	-- MESH_USE_LIGHT = 0x1<<7: use block ambient and diffuse lighting for this model. 
	model:SetAttribute(0x8080, true);
	model:SetField("RenderDistance", 100);
	if(self:HasRealPhysics()) then
		model:SetField("EnablePhysics", true);
	end

	self:SetInnerObject(model);
	ParaScene.Attach(model);
	return model;
end

function Entity:getYaw()
	return self:GetFacing();
end

function Entity:setYaw(yaw)
	if(self:getYaw() ~= yaw) then
		self:SetFacing(yaw);
		self:valueChanged();
	end
end

function Entity:getScale()
	return self.scale or 1;
end

function Entity:setScale(scale)
	if(self.scale ~= scale) then
		self.scale = scale;
		local obj = self:GetInnerObject();
		if(obj) then
			obj:SetScale(scale);
		end
		self:valueChanged();
	end
end

function Entity:EndEdit()
	Entity._super.EndEdit(self);
end

function Entity:Destroy()
	self:DestroyInnerObject();
	Entity._super.Destroy(self);
end

function Entity:Refresh()
	local obj = self:GetInnerObject();
	if(obj) then
		obj:SetField("assetfile", self:GetModelDiskFilePath() or self.default_file);
	end
end


function Entity:EndEdit()
	Entity._super.EndEdit(self);
	self:MarkForUpdate();
end

function Entity:LoadFromXMLNode(node)
	Entity._super.LoadFromXMLNode(self, node);
	local attr = node.attr;
	if(attr) then
		if(attr.filename) then
			self:SetModelFile(attr.filename);
		end
		if(attr.scale) then
			self:setScale(tonumber(attr.scale));
		end
	end
end

function Entity:SetModelFile(filename)
	self.filename = filename;
end

function Entity:GetModelFile()
	return self.filename;
end

function Entity:SaveToXMLNode(node)
	node = Entity._super.SaveToXMLNode(self, node);
	node.attr.filename = self:GetModelFile();
	if(self:getScale()~= 1) then
		node.attr.scale = self:getScale();
	end
	return node;
end

-- Overriden in a sign to provide the text.
function Entity:GetDescriptionPacket()
	local x,y,z = self:GetBlockPos();
	return Packets.PacketUpdateEntityBlock:new():Init(x,y,z, self:GetModelFile(), self:getYaw(), self:getScale());
end

-- update from packet. 
function Entity:OnUpdateFromPacket(packet_UpdateEntityBlock)
	if(packet_UpdateEntityBlock:isa(Packets.PacketUpdateEntityBlock)) then
		local filename = packet_UpdateEntityBlock.data1;
		local yaw = packet_UpdateEntityBlock.data2;
		local scaling = packet_UpdateEntityBlock.data3;
		if(filename) then
			self:SetModelFile(filename);
		end
		if(yaw) then
			self:setYaw(yaw);
		end
		if(scaling) then
			self:setScale(scaling);
		end
		self:Refresh();
	end
end

-- right click to show item
function Entity:OnClick(x, y, z, mouse_button)
	local obj = self:GetInnerObject();
	if(obj) then
		-- check if the entity has mount position. If so, we will set current player to this location.  
		if(obj:HasAttachmentPoint(0)) then
			local x, y, z = obj:GetAttachmentPosition(0);
			local entityPlayer = EntityManager.GetPlayer();
			if(entityPlayer) then
				entityPlayer:SetPosition(x,y,z);
			end
			return true;
		end
	end
end

function Entity:OnBlockAdded(x,y,z)
	if(not self.facing) then
		--self.facing = Direction.GetFacingFromCamera();
		self.facing = Direction.directionTo3DFacing[Direction.GetDirection2DFromCamera()];
		local obj = self:GetInnerObject();
		if(obj) then
			obj:SetFacing(self.facing);
		end
	end
end

-- called every frame
function Entity:FrameMove(deltaTime)
end