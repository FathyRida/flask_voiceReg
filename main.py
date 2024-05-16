# Importations nécessaires pour l'application Flask et diverses fonctionnalités
from flask import Flask, request, jsonify, render_template, send_file, session
from dotenv import load_dotenv
import requests, os, datetime, tempfile, pyttsx3
from flask_cors import CORS
import speech_recognition as sr
import subprocess
from gtts import gTTS
from flask_session import Session 
from openai import OpenAI


# Génération d'une clé secrète pour les sessions
secret_key = os.urandom(24)
print(secret_key)

# Initialisation du reconnaissance vocale
recognizer = sr.Recognizer()
recognizer.energy_threshold = 200
recognizer.pause_threshold = 0.2
recognizer.non_speaking_duration = 0.1

# Initialisation de l'engine TTS (Text-To-Speech)
engine = pyttsx3.init()
engine.setProperty('rate', 150)
engine.setProperty('volume', 0.9)

# Chargement des variables d'environnement depuis le fichier .env
load_dotenv()

# Initialisation de l'application Flask
app = Flask(__name__, static_url_path='')
app.secret_key = "21z60vx=xsixi4o#1x2-*^=ar=ckic%v5xtf06+1*wj*8q&sox-t12"
app.config['SESSION_TYPE'] = 'filesystem'
app.config['SESSION_FILE_DIR'] = './sessions'
Session(app)
CORS(app)

# Récupération des clés API depuis les variables d'environnement
OPENWEATHER_API_KEY = os.getenv("OPENWEATHER_API_KEY")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")

# Open AI Initialisation de  l'engine 
client = OpenAI(api_key=os.environ.get("OPENAI_API_KEY"))
MODEL = "gpt-3.5-turbo"

# Définition de la fonction pour gérer les commandes textuelles
def handle_command(text):
    """Gère les commandes basées sur le texte entré par l'utilisateur."""
    # Analyse et réponse en fonction du contenu du texte
    if "présente-toi" in text:
        return "D'accord, je suis EVA une assistante vocale développée par Maryam et Nidal. Je suis ici pour vous aider à obtenir des informations. Je peux vous informer sur la météo, l'heure et date, répondre à vos questions grâce à l'intelligence artificielle. N'hésitez pas à me demander de l'aide à tout moment!"
    elif "au revoir" in text:
        return "Au revoir!"
    elif "bonjour" in text:
        return "Bonjour, je suis votre assistante vocale. Comment je peux vous aider aujourd'hui?"
    elif "date" in text and "heure" in text:
        return "Il est " + datetime.datetime.now().strftime("%H:%M") + " le " + datetime.datetime.now().strftime("%d %B %Y")
    elif "date" in text:
        return "Nous sommes le " + datetime.datetime.now().strftime("%d %B %Y")
    elif "heure" in text:
        return "Il est " + datetime.datetime.now().strftime("%H:%M")
    elif "météo" in text:
        return "Pour quelle ville souhaitez-vous connaître la météo ?"
    else:
        return "Je n'ai pas compris votre demande."

# Fonction pour obtenir la météo d'une ville spécifique
def get_weather(city_name):
    """Interroge l'API OpenWeatherMap pour obtenir des informations météorologiques pour une ville donnée."""
    base_url = "http://api.openweathermap.org/data/2.5/weather?"
    complete_url = f"{base_url}appid={OPENWEATHER_API_KEY}&q={city_name}&units=metric"
    response = requests.get(complete_url)
    data = response.json()
    
    if data["cod"] != "404":
        main = data["main"]
        temperature = main["temp"]
        pressure = main["pressure"]
        humidity = main["humidity"]
        weather_description = data["weather"][0]["description"]
        weather_info = (f"Température : {temperature}°C, Pression : {pressure} hPa, Humidité : {humidity}%, Description : {weather_description}.")
        return weather_info
    else:
        return "Informations météorologiques non trouvées."

def text_to_speech(text):
    """Converts text to speech using gTTS and saves it to a temporary .mp3 file."""
    tts = gTTS(text=text, lang='fr')
    with tempfile.NamedTemporaryFile(delete=False, suffix='.mp3') as fp:
        tts.save(fp.name)
        return fp.name

# Fonction pour obtenir la date actuelle
def get_current_date():
    """Retourne la date actuelle formatée."""
    today = datetime.date.today()
    return "Aujourd'hui c'est " + today.strftime("%d %B %Y")
    
def get_current_time():
    """Returns the current time formatted."""
    return datetime.datetime.now().strftime("%H:%M")

# Route pour servir la page d'accueil
@app.route('/')
def index():
    return render_template('index.html')

# Route pour obtenir la date actuelle et la retourner sous forme de discours
@app.route('/get-date-speech', methods=['GET'])
def fetch_date_speech():
    date_info = get_current_date()
    audio_file_path = text_to_speech(date_info)
    return send_file(audio_file_path, as_attachment=True, mimetype='audio/mp3')

# Route pour obtenir la météo basée sur une requête POST contenant le nom de la ville
@app.route('/get-weather', methods=['POST'])
def web_get_weather():
    data = request.json
    city_name = data.get('city_name')
    if city_name:
        weather_info = get_weather(city_name)
        return jsonify({'weather_info': weather_info})
    else:
        return jsonify({'error': 'No city provided'}), 400

# Route pour obtenir la date actuelle et la retourner en JSON
@app.route('/get-date', methods=['GET'])
def fetch_date():
    date_info = get_current_date()
    return jsonify({'date_info': date_info})

# Route pour traiter l'audio envoyé, reconnaître le discours, et répondre en conséquence
@app.route('/process-audio', methods=['POST'])
def process_audio():
    if 'audio' not in request.files:
        return jsonify({"error": "No audio file provided"}), 400

    if 'context' not in session:
        session['context'] = None

    audio_file = request.files['audio']
    text = transcribe_audio(audio_file)
    response_text, next_context = generate_response(text, session.get('context'))
    session['context'] = next_context

    tts = gTTS(text=response_text, lang='fr')
    tts_file = tempfile.NamedTemporaryFile(delete=False, suffix='.mp3')
    tts.save(tts_file.name)

    return send_file(tts_file.name, mimetype='audio/mp3', as_attachment=True, download_name='response.mp3')

def transcribe_audio(audio_file):
    """Convertit l'audio en texte en utilisant Google Speech Recognition."""
    with tempfile.NamedTemporaryFile(delete=True, suffix='.webm') as tmp:
        audio_file.save(tmp.name)
        output_wav = tempfile.NamedTemporaryFile(delete=True, suffix='.wav')
        subprocess.run(['ffmpeg', '-y', '-i', tmp.name, '-acodec', 'pcm_s16le', '-ar', '16000', '-ac', '1', output_wav.name], check=True)
        recognizer = sr.Recognizer()
        with sr.AudioFile(output_wav.name) as source:
            audio_data = recognizer.record(source)
            return recognizer.recognize_google(audio_data, language="fr-FR")

def generate_response(input_text, context):
    """Generate a response based on the input text and context."""
    input_text = input_text.lower().strip()  # Normalize input to lower case and strip whitespace
    
    # Handle context-related responses first
    if context == "asking_for_city":
        if input_text:
            weather_info = get_weather(input_text)  # Assume get_weather() is correctly implemented to fetch weather
            return f"La météo à {input_text} est {weather_info}", None
        else:
            return "Je n'ai pas entendu le nom de la ville. Pour quelle ville souhaitez-vous la météo ?", "asking_for_city"
    elif context == "expecting_question":
        # Assume here we would process the question and fetch an answer
        answer = process_question(input_text)
        return answer, None  # Clear the context after answering

    # Handling commands based on initial or new user input
    if "présente-toi" in input_text:
        response = ("D'accord, je suis EVA, une assistante vocale développée par Maryam et Nidal. "
                    "Je suis ici pour vous aider à obtenir des informations, vous informer sur la météo, "
                    "l'heure et la date, et répondre à vos questions grâce à l'intelligence artificielle. "
                    "N'hésitez pas à me demander de l'ai    de à tout moment!")
        return response, None
    elif "au revoir" in input_text:
        return "Au revoir!", None
    elif "merci" in input_text:
        return "avec plaisir n#hesite pas a pose d'autres questiones", None
    elif "bonjour" in input_text:
        return "Bonjour, je suis votre assistante vocale. Comment puis-je vous aider aujourd'hui ?", None
    elif "date" in input_text and "heure" in input_text:
        date_info = get_current_date() 
        time_info = get_current_time() 
        return f"Il est {time_info} et nous sommes le {date_info}.", None
    elif "date" in input_text:
        return "Nous sommes le " + get_current_date(), None  # get_current_date() should return the formatted date
    elif "heure" in input_text:
        return "Il est " + get_current_time(), None  # get_current_time() should return the formatted time
    elif "météo" in input_text:
        return "Pour quelle ville souhaitez-vous connaître la météo ?", "asking_for_city"
    elif "question" in input_text:
        return "Quelle est votre question ?", "expecting_question"

    # Default response if no recognized command
    return "Je n'ai pas compris votre demande. Pouvez-vous répéter ?", None

def process_question(question):
    """Process the user's question and return an answer."""
    try:
        #envoyer une requete à l'API OpenAI
        response = client.chat.completions.create(
            model="gpt-3.5-turbo-16k",
            messages=[
                {"role": "system", "content": 'You answer question about Web  services.'
                 },
                {"role": "user", "content": question},
            ]
        )
        #afficher le contenu de la réponse obtenue par GPT
        print(response.choices[0].message.content)
        return response.choices[0].message.content
    except Exception as e:
        print(f"Error: {e}")
        return "j'ai rencontré une erreur lors du traitement de votre demande."

 



if __name__ == '__main__':
    app.run()
    # app.run(debug=True,host='0.0.0.0')

