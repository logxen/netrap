#ifndef _PRINTER_HPP

#include "socket.hpp"
#include "queuemanager.hpp"

#include <string>
#include <map>

class Printer;
class Printer : public Socket {
public:
	Printer(void);
	Printer(int fd);
	Printer(char *port, int baud);
	~Printer(void);
	
	int open(char *port, int baud);
	
	char **listCapabilities();
	char *getCapability(char *capability);
	void setCapability(char *capability, char *value);

	char **listProperties();
	char *getProperty(char *property);
	void setProperty(char *property, char *value);

	int write(string str);
	int write(const char *str, int len);

	int read(char *buffer, int buflen);
protected:
	void init();
	QueueManager queuemanager;
	map<string, string> properties;
	map<string, string> capabilities;

	static std::list<Printer *> allprinters;
private:
};

#endif /* _PRINTER_HPP */
