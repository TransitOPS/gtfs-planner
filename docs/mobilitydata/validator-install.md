# Canonical GTFS Schedule Validator

### Setup

1. Install Java 17 or higher. To check which version of Java is installed on your computer, type the following command in the terminal: `java --version`. You can download Java from one of the following sources:
   - **[Eclipse Adoptium (Temurin)](https://adoptium.net/temurin/releases/)** – Open-source & widely used
   - **[Amazon Corretto](https://aws.amazon.com/corretto/)** - AWS-supported, optimized for cloud
   - **[Azul Zulu](https://www.azul.com/downloads/)** - Enterprise ready
   - **[Microsoft Build of OpenJDK](https://learn.microsoft.com/en-us/java/openjdk/download/)** - Microsoft's JDK
   - **[Oracle JDK](https://www.oracle.com/java/technologies/javase-downloads.html)** - Official Java from Oracle
2. Navigate to the [Releases page](https://github.com/MobilityData/gtfs-validator/releases) and download the latest `Gtfs Validator` CLI jar (not OS-specific). It is located in the **Assets** section of the release, and it looks like `gtfs-validator-vX.X.X-cli.jar`
3. Open the terminal on your computer
4. Navigate to the directory containing the jar file. You can do this by typing the following command in the terminal:`cd {directory path}`, where {directory path} is the absolute or relative path to the directory. You can then make sure you're in the right directory by typing `pwd` in the terminal (this stands for _present working directory_). You can also make sure the jar file is there by typing `ls` in the terminal (this stands for _list_ and will display the list of files in this directory). More about commands to navigate file and directories [here](https://help.ubuntu.com/community/UsingTheTerminal#File_.26_Directory_Commands).

### Run it

You can run this validator using a GTFS dataset on your computer, or from a URL.

- To validate a GTFS dataset on your computer, run the following command in the terminal, replacing the text in brackets:
  - `java -jar {name of the jar file} -i {path to the GTFS file} -o {name of the output directory that will be created}`
  - here is an example of what the command could look like: `java -jar gtfs-validator-cli.jar -i /myDirectory/gtfs.zip -o output`

- To validate a GTFS dataset from a URL, run the following command in the terminal, replacing the text in brackets:
  - `java -jar {name of the jar file} -u {URL to the GTFS file} -o {name of the output directory that will be created}`
  - here is an example of what the command could look like: `java -jar gtfs-validator-cli.jar -u https://www.abc.com/gtfs.zip -o output`
