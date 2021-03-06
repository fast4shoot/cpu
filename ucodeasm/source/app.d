import std.getopt;
import std.algorithm;
import std.conv;
import std.exception;
import std.file;
import std.stdio;
import std.typecons;
import pegged.grammar;

mixin(grammar("
uCode:
	Program < Line* eoi
	Spacing <- space*
	
	Line < LiteralAddress? Label? Instruction? Goto? :Comment? :eol?
	Comment <- :'#' (!eol .)*
	LiteralAddress <- :'at' :space+ ~(hexDigit+)
	Instruction <- (InstructionPart :space*)+
	InstructionPart <- 'ldData' / 'instJmp' / 'ipInc' / 'aluToDb' / 'dstToDb' / 'regWrite' / 'memClk' / 'memWrite' / 'dataToDb' / 'aluPassthrough'
	Goto <- :'goto' :space+ identifier
	Label < identifier :':'
"));

int main(string[] args)
{
	string oFile;
	bool help = false;

	getopt(
		args,
		"help|h", &help,
		"output|o", &oFile
	);
	
	if(help||oFile is null)
	{
		writeln("Usage: ucode [OPTION] [STRING]");
		writeln("-h, --help");
		writeln("    print this help");
		writeln("-o, --output");
		writeln("write to file");
		return 0;
	}

	string source;         
	foreach(line; stdin.byLine())
	{
		source ~= line ~ '\n';
	}

	auto pt = uCode(source);
	if (!pt.successful)
	{
		stderr.writeln(pt);
		return 1;
	}
	
	struct Instruction
	{
		ushort nextAddress;
		ushort instruction;
		string gotoLabel;
	}
	
	immutable bitMapping = [
		//"ldInst" : 1<<0,
		"ldData" : 1<<1,
		"instJmp" : 1<<2,
		"ipInc" : 1<<3,
		"aluToDb" : 1<<4,
		"dstToDb" : 1<<5,
		"regWrite" : 1<<6,
		"memClk" : 1<<7,
		"memWrite" : 1<<8,
		"dataToDb" : 1<<9,
		"aluPassthrough" : 1 << 10
	];
	
	uint ip = 0;
	ushort[string] labels;
	Nullable!Instruction[] instructions;
	uint totalInstructions = 0;
	
	foreach (ref line; pt.children[0].children)
	{
		if (ip == 0x10000)
		{
			throw new Exception("Can't exceed memory of 64 KiB");
		}
		
		Nullable!ushort address;
		string label = null;
		Nullable!ushort instruction;
		string gotoLabel = null;
		
		foreach (ref element; line.children)
		{
			switch (element.name)
			{
				case "uCode.LiteralAddress":
					address = parse!ushort(element.matches[0], 16);
					break;
				
				case "uCode.Label":
					label = element.matches[0];
					break;
				
				case "uCode.Instruction":
					instruction = 0;
					
					foreach (ref part; element.children)
					{
						instruction |= bitMapping[part.matches[0]];
					}
					break;
				
				case "uCode.Goto":
					gotoLabel = element.matches[0];
					break;
					
				default:
					throw new Exception("EVERYTHING'S FUCKED");
			}
		}
		
		if (!address.isNull)
		{
			if (address.get() < ip)
			{
				throw new Exception("Can't go back, man");
			}
			
			ip = address.get();
		}
		
		if (label !is null)
		{
			if (label in labels)
			{
				throw new Exception("Duplicate label '" ~ label ~ "'");
			}
			else
			{
				labels[label] = ip.to!ushort;
			}
		}
		
		if (!instruction.isNull || gotoLabel !is null)
		{
			instructions.length = ip + 1;
			instructions[ip] = Instruction(0, instruction.isNull ? 0 : instruction.get(), gotoLabel);
			ip++;
			totalInstructions++;
		}
	}
	
	writefln("Populated %s B with %s instructions. Resolving labels...", instructions.length, totalInstructions);
	uint referencedLabels = 0;
	
	foreach (i, ref instruction; instructions)
	{
		if (!instruction.isNull)
		{
			if (instruction.gotoLabel !is null)
			{
				auto label = instruction.gotoLabel;
				ushort* address = label in labels;
				enforce (address !is null, "Undefined reference to '" ~ label ~ "'");
				instruction.nextAddress = *address;
				referencedLabels++;
			}
			else
			{
				enforce (instructions.length > (i + 1) && !instructions[i + 1].isNull,
					text("No followup to instruction at address ", i));
				instruction.nextAddress = (i + 1).to!ushort;
			}
		}
	}
	
	writefln("Resolved %s labels. Writing result to file %s...", referencedLabels, oFile);
	
	auto of = File(oFile, "wb");
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
			uint value = (instruction.nextAddress << 16) | instruction.instruction;
			of.writef("%x ", value);
		}
	}
	
	of.close();
	writeln("Done");
	
	return 0;
}
