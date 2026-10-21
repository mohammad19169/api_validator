const petStoreYaml = r'''
openapi: 3.0.3
info:
  title: Pet Store
  version: 1.0.0
servers:
  - url: https://api.example.com/v1
security:
  - bearer: []
paths:
  /pets:
    get:
      operationId: listPets
      parameters:
        - name: limit
          in: query
          schema: { type: integer, minimum: 1, maximum: 100 }
        - name: tags
          in: query
          schema:
            type: array
            items: { type: string }
      responses:
        '200':
          description: ok
          headers:
            X-Total:
              required: true
              schema: { type: integer }
          content:
            application/json:
              schema:
                type: array
                items: { $ref: '#/components/schemas/Pet' }
        default:
          description: error
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Error' }
    post:
      operationId: createPet
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/NewPet' }
      responses:
        '201':
          description: created
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Pet' }
        4XX:
          description: client error
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Error' }
  /pets/{petId}:
    parameters:
      - name: petId
        in: path
        required: true
        schema: { type: integer, format: int64 }
    get:
      operationId: getPet
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Pet' }
        '404':
          description: missing
    delete:
      operationId: deletePet
      deprecated: true
      responses:
        '204':
          description: deleted
  /pets/mine:
    get:
      operationId: myPets
      security: []
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: array
                items: { $ref: '#/components/schemas/Pet' }
  /shapes:
    post:
      operationId: createShape
      security: []
      requestBody:
        content:
          application/json:
            schema: { $ref: '#/components/schemas/Shape' }
      responses:
        '200':
          description: ok
components:
  securitySchemes:
    bearer:
      type: http
      scheme: bearer
  schemas:
    NewPet:
      type: object
      required: [name]
      properties:
        id: { type: integer, readOnly: true }
        name: { type: string, minLength: 1 }
        tag: { type: string, nullable: true }
        status: { type: string, enum: [available, sold] }
        birthday: { type: string, format: date }
    Pet:
      allOf:
        - $ref: '#/components/schemas/NewPet'
        - type: object
          required: [id]
          properties:
            id: { type: integer, readOnly: true }
            owner: { $ref: '#/components/schemas/Owner' }
    Owner:
      type: object
      nullable: true
      properties:
        email: { type: string, format: email }
    Error:
      type: object
      required: [code, message]
      properties:
        code: { type: integer }
        message: { type: string }
    Shape:
      oneOf:
        - $ref: '#/components/schemas/Circle'
        - $ref: '#/components/schemas/Square'
      discriminator:
        propertyName: kind
        mapping:
          circle: '#/components/schemas/Circle'
          square: Square
    Circle:
      type: object
      required: [kind, radius]
      properties:
        kind: { type: string }
        radius: { type: number, exclusiveMinimum: true, minimum: 0 }
    Square:
      type: object
      required: [kind, side]
      properties:
        kind: { type: string }
        side: { type: number }
''';

const openApi31Json = r'''
{
  "openapi": "3.1.0",
  "info": {"title": "Modern", "version": "2"},
  "paths": {
    "/items/{id}.json": {
      "get": {
        "parameters": [
          {"name": "id", "in": "path", "required": true,
           "schema": {"type": "string", "pattern": "^[a-z]+$"}}
        ],
        "responses": {
          "200": {
            "description": "ok",
            "content": {
              "application/json": {
                "schema": {"$ref": "#/components/schemas/Item"}
              }
            }
          }
        }
      }
    }
  },
  "components": {
    "schemas": {
      "Item": {
        "type": "object",
        "required": ["id", "tags"],
        "properties": {
          "id": {"type": "string"},
          "note": {"type": ["string", "null"]},
          "score": {"type": "number", "exclusiveMinimum": 0},
          "tags": {"type": "array", "prefixItems": [{"const": "first"}],
                   "items": {"type": "string"}},
          "child": {"$ref": "#/components/schemas/Item"}
        }
      }
    }
  }
}
''';
