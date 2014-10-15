import std.getopt;
import std.algorithm;
import std.array;
import std.bitmanip : bitfields;
import std.conv;
import std.exception;
import std.file;
import std.stdio;
import std.typecons;
import pegged.grammar;

mixin(grammar("
code:
	Program < Line* eoi
	Spacing <- space*
	
	Line < LiteralAddress? Label? Instruction? :Comment? :eol?
	Comment <- :'#' (!eol .)*
	LiteralAddress <- :'at' :space+ ~(hexDigit+)
	Label < ;LabelName :':'
	Instruction <- NoneInstruction 
				 / RegInstruction 
				 / RegRegInstruction 
				 / RegImmInstruction 
				 / RegDerefInstruction 
				 / DerefRegInstruction
	
	NoneInstruction < 'nop'
	RegInstruction < ('ld0' / 'ld1') ;Register
	RegRegInstruction < (
						/ 'mov' 
						/ 'shl'
						/ 'shr'
						/ 'add'
						/ 'sub'
						/ 'nand'
						/ 'neg'
						/ 'inc'
						/ 'dec') ;Register :','? ;Register
	RegImmInstruction < 'mov' ;Register :','? Immediate
	RegDerefInstruction < 'mov' ;Register :','? ;Deref
	DerefRegInstruction < 'mov' ;Deref :','? ;Register
	
	Register <- (:'r' [0-7]) / 'ip'
	Immediate <- DecImm / HexImm / LabelName
	DecImm <- ~([1-9][0-9]+)
	HexImm <- :'0x' ~(hexDigit+)
	LabelName <- identifier
	Deref <- :'[' Register :']'
"));

unittest
{
	code("
		at 0
		ass:
		mov r0 r1
		mov r0 [r1]
		mov [r0] r1
		mov r0 1234
		mov r0 0x1234
		mov r0 ass
		
		at 1f label: mov r0, r1
		mov r0, [r1]
		mov [r0], r1
		mov r0, 1234
		mov r0, 0x1234
		mov r0, ass
		");
}

enum noneInstructionCode = 0x00;
enum regInstructionCode = 0x01;
enum regRegInstructionCode = 0x01;
enum regImmInstructionCode = 0x02;
enum regDerefInstructionCode = 0x03;
enum derefRegInstructionCode = 0x04;

enum aluMov = 0x00;
enum aluShl = 0x01;
enum aluShr = 0x02;
enum aluAdd = 0x03;
enum aluSub = 0x04;
enum aluNand = 0x05;
enum aluNeg = 0x06;
enum aluLd0 = 0x07;
enum aluLd1 = 0x08;
enum aluInc = 0x09;
enum aluDec = 0x0a;

enum memSize = 0x10000;

struct Instruction
{
	union
	{
		ushort value;
		struct
		{
			mixin(bitfields!(
				uint, "src", 3,
				uint, "dst", 3,
				uint, "alu", 4,
				uint, "instruction", 6));
		}
	}
	string label;
}

import std.typecons : Tuple;
alias Immediate = Tuple!(ushort, "value", string, "label");

int main(string[] args)
{
	string oFile;
	bool help = false;

	getopt(
		args,
		"help|h", &help,
		"output|o", &oFile
	);
	
	if (help || oFile is null)
	{
		stderr.writeln("Usage: ucode [OPTION]");
		stderr.writeln("-h, --help");
		stderr.writeln("    print this help");
		stderr.writeln("-o, --output");
		stderr.writeln("    write to file");
		return 0;
	}

	string source = cast(string) stdin.byLine(KeepTerminator.yes).join;      
	foreach (line; stdin.byLine())
	{
		source ~= line ~ '\n';
	}

	auto pt = code(source);
	if (!pt.successful)
	{
		stderr.writeln(pt);
		return 1;
	}

	uint ip = 0;
	ushort[string] labels;
	Nullable!Instruction[] instructions;
	uint totalInstructions = 0;
	uint totalImmediates = 0;
	
	void addInstructionImpl(Instruction inst)
	{
		if (ip >= memSize)
		{
			throw new Exception("ip overflow");
		}
		
		instructions.length = ip + 1;
		instructions[ip] = inst;
		ip++;
	}
	
	void addInstruction(Instruction inst)
	{
		addInstructionImpl(inst);
		totalInstructions++;
	}
	
	void addImmediate(Immediate imm)
	{
		Instruction rep;
		rep.value = imm.value;
		rep.label = imm.label;
		addInstructionImpl(rep);
		totalImmediates++;
	}
	
	foreach (ref element; pt.children[0].children.map!(line => line.children).joiner)
	{
		
		switch (element.name)
		{
			case "code.LiteralAddress":
				auto address = parse!ushort(element.matches[0], 16);
				enforce(address >= ip, text("Literal address ", address, " must be larger or equal to IP, which is ", ip));
				ip = address;
				break;
			
			case "code.Label":
				auto label = element.matches[0];
				if (label in labels)
				{
					throw new Exception("Duplicate label '" ~ label ~ "'");
				}
				else
				{
					labels[label] = ip.to!ushort;
				}
				break;
			
			case "code.Instruction":
				Instruction instRep;
				Instruction valueRep;
				auto inst = element.children[0];
				
				switch (inst.name)
				{
					case "code.NoneInstruction":
						instRep.instruction = noneInstructionCode;
						addInstruction(instRep);
						break;
						
					case "code.RegInstruction":
						instRep.instruction = regInstructionCode;
						instRep.dst = inst.matches[1].parseRegister;
						instRep.alu = inst.matches[0].parseAluOp;					
						addInstruction(instRep);
						break;
					
					case "code.RegRegInstruction":
						instRep.instruction = regRegInstructionCode;
						instRep.dst = inst.matches[1].parseRegister;
						instRep.src = inst.matches[2].parseRegister;
						instRep.alu = inst.matches[0].parseAluOp;
						addInstruction(instRep);
						break;
					
					case "code.RegImmInstruction":
						instRep.instruction = regImmInstructionCode;
						instRep.dst = inst.matches[1].parseRegister;
						addInstruction(instRep);
						addImmediate(inst.children[0].children[0].parseImmediate);
						break;
					
					case "code.RegDerefInstruction":
						instRep.instruction = regDerefInstructionCode;
						instRep.dst = inst.matches[1].parseRegister;
						instRep.src = inst.matches[2].parseRegister;
						addInstruction(instRep);
						break;
						
					case "code.DerefRegInstruction":
						instRep.instruction = derefRegInstructionCode;
						instRep.src = inst.matches[1].parseRegister;
						instRep.dst = inst.matches[2].parseRegister;
						addInstruction(instRep);
						break;
						
					default:
						throw new Exception("EVERYTHING'S FUCKED: " ~ inst.name);
				}
				
				break;
				
			default:
				throw new Exception("EVERYTHING'S FUCKED: " ~ element.name);
		}
	}
	
	stderr.writefln("Populated %s B with %s instructions and %s immediates. Resolving labels...", instructions.length, totalInstructions, totalImmediates);
	uint referencedLabels = 0;
	
	foreach (i, ref instruction; instructions)
	{
		if (!instruction.isNull)
		{
			if (instruction.label !is null)
			{
				auto label = instruction.label;
				ushort* address = label in labels;
				enforce (address !is null, "Undefined reference to '" ~ label ~ "'");
				instruction.value = *address;
				referencedLabels++;
			}
		}
	}
	
	stderr.writefln("Resolved %s labels. Writing result to file %s...", referencedLabels, oFile);
	
	auto of = File(oFile, "wb");
	scope(exit) of.close();
	of.write("v2.0 raw");
	
	foreach (i, ref instruction; instructions)
	{
		if (i % 8 == 0)
		{
			of.writeln();
		}
		
		if (instruction.isNull)
		{
			of.write("0 ");
		}
		else
		{
			of.writef("%x ", instruction.value);
		}
	}
	
	stderr.writeln("Done");
	
	return 0;
}

pure uint parseRegister(string reg)
{
	if (reg == "ip")
	{
		return 0;
	}
	else
	{
		return reg.to!uint;
	}
}

pure uint parseAluOp(string op)
{
	import std.string;
	op = op.toLower;
	switch (op)
	{
		case "mov": 
			return aluMov;
		case "shl":
			return aluShl;
		case "shr":
			return aluShr;
		case "add":
			return aluAdd;
		case "sub":
			return aluSub;
		case "nand":
			return aluNand;
		case "neg":
			return aluNeg;
		case "inc":
			return aluInc;
		case "dec":
			return aluDec;
		case "ld0":
			return aluLd0;
		case "ld1":
			return aluLd1;
		default:
			throw new Exception("parseAluOp: unknown operation " ~ op ~ ", bug?");
	}
}

pure Immediate parseImmediate(ParseTree tree)
{	
	switch (tree.name)
	{
		case "code.HexImm":
			return Immediate(tree.matches[0].parse!ushort(16), null);
			
		case "code.DecImm":
			return Immediate(tree.matches[0].parse!ushort(10), null);
			
		case "code.LabelName":
			return Immediate(0, tree.matches[0]);
		
		default:
			throw new Exception("parseImmediate: unknown immediate type " ~ tree.name ~ ", bug?");
	}
}
