module c3voxel;
import std::io;
import std::os;
import std::math;

import glfw;
import opengl;
import opengl::gl;

const char* VERTEX_SHADER = `
  #version 410

  layout( location = 0 ) in vec3 vp;
  layout( location = 1 ) in vec3 vcolor;

  out vec3 theColor;

  void main () {
    theColor = vcolor;
    gl_Position = vec4(vp, 1.0);
  }
`;

const char* FRAGMENT_SHADER = `
  #version 410

  in vec3 theColor;
  out vec4 frag_colour;

  void main () {
    frag_colour = vec4(theColor, 1.0);
  }
`;

float[] triangleData = {
    -0.5, -0.5, 0.0, 1.0, 0.5, 1.0,
     0.5, -0.5, 0.0, 1.0, 0.5, 1.0,
     0.0,  0.5, 0.0, 1.0, 0.5, 1.0
};

float [] indices = {
	0, 1, 3,
	1, 2, 3	
};

faultdef FILE_NOT_FOUND, FILE_NOT_READABLE, FAILED;

fn int main(String[] args)
{
	glfw::init();
	glfw::windowHint(glfw::CONTEXT_VERSION_MAJOR, 4);
	glfw::windowHint(glfw::CONTEXT_VERSION_MINOR, 6);
	glfw::windowHint(glfw::OPENGL_PROFILE, glfw::OPENGL_CORE_PROFILE);
	glfw::windowHint(glfw::OPENGL_FORWARD_COMPAT, 1);

	glfw::GlfwWindow* window = glfw::createWindow(800, 600, "c3voxel", null, null);
	if (window == null) {
		io::eprintn("Failed to create GLFW window");
		glfw::terminate();
		std::os::exit(1);
	}

	glfw::makeContextCurrent(window);

	if (catch excuse = opengl::init((GLLoadFn)&glfw::getProcAddress)) {
		io::eprintfn("Failed to initialize OpenGL: ", excuse);
		glfw::destroyWindow(window);
		glfw::terminate();
		std::os::exit(1);
	}

	ZString renderer = (ZString)gl::getString(gl::GL_RENDERER);
	ZString version = (ZString)gl::getString(gl::GL_VERSION);

	io::printfn("Renderer: %s", renderer);
	io::printfn("OpenGL version supported: %s", version);

	gl::enable(gl::GL_DEPTH_TEST);
	gl::depthFunc(gl::GL_LESS);

	int triangleSize = triangleData.len * float.sizeof;

	uint vertexBuffer;
	uint vao;

	gl::genBuffers(1, &vertexBuffer);
	gl::bindBuffer(gl::GL_ARRAY_BUFFER, vertexBuffer);
	gl::bufferData(gl::GL_ARRAY_BUFFER, triangleSize, triangleData, gl::GL_STATIC_DRAW);

	gl::genVertexArrays(1, &vao);
	gl::bindVertexArray(vao);

	defer {
		gl::deleteBuffers(1, &vertexBuffer);
		gl::deleteVertexArrays(1, &vao);
	}

	uint? vertexShader = createShader(gl::GL_VERTEX_SHADER, &VERTEX_SHADER);
	uint? fragmentShader = createShader(gl::GL_FRAGMENT_SHADER, &FRAGMENT_SHADER);

	if (catch excuse = vertexShader, fragmentShader) {
		io::eprintfn("Failed to create shader: %s", excuse);
		glfw::destroyWindow(window);
		glfw::terminate();
		std::os::exit(1);
	}

	uint shaderProgram = gl::createProgram();

	defer {
		gl::detachShader(shaderProgram, vertexShader);
		gl::detachShader(shaderProgram, fragmentShader);
		gl::deleteShader(vertexShader);
		gl::deleteShader(fragmentShader);
		gl::deleteProgram(shaderProgram);
	}

	gl::attachShader(shaderProgram, vertexShader);
	gl::attachShader(shaderProgram, fragmentShader);
	gl::linkProgram(shaderProgram);

	gl::enableVertexAttribArray(0);
	gl::vertexAttribPointer(0, 3, gl::GL_FLOAT, 0, 6 * float.sizeof, null);

	gl::enableVertexAttribArray(1);
	gl::vertexAttribPointer(1, 3, gl::GL_FLOAT, 0, 6 * float.sizeof, (void*)(3 * float.sizeof));

	while(glfw::windowShouldClose(window) == 0) {
		gl::clear(gl::GL_COLOR_BUFFER_BIT | gl::GL_DEPTH_BUFFER_BIT);
		gl::useProgram(shaderProgram);
		gl::drawArrays(gl::GL_TRIANGLES, 0, 6);


		glfw::pollEvents();
		glfw::swapBuffers(window);
	}

	glfw::destroyWindow(window);
	glfw::terminate();

	return 0;
}

fn float toRadians(float value) {
    return value * (float)math::PI / 180;
}

fn uint? createShader(GLenum shadertype, char** resources) {
  int shader = gl::createShader( shadertype );
  gl::shaderSource( shader, 1, resources, null );
  gl::compileShader( shader );

  int success;
  char[512] infoLog;
  gl::getShaderiv(shader, gl::GL_COMPILE_STATUS, &success);

  if (!success) {
		gl::getShaderInfoLog(shader, 512, null, &infoLog);
        io::eprintfn("Shader failed with error message %s", infoLog);
        return FAILED~;
	} else {
        return shader;
    }
}