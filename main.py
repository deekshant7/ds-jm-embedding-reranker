from fastapi import FastAPI
from pydantic import BaseModel
from typing import List
import re
import torch
import time
import logging
import pandas as pd
import numpy as np
from scipy.spatial.distance import cosine
from collections import Counter
import uvicorn
import logging
import json
from typing import Dict, Any

# Initialize FastAPI app with metadata
print("Initialising FASTAPI Server")
app = FastAPI(
    title="Embedding Reranker Service",
    description="ML service to generate Embedding from SMS body",
    version="0.0.1",
)
print("FASTAPI Server Initialisation done")

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('app.log'),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)



def clean_text_2(text): 
    text = text.lower() 
    #text = re.sub('<[^<]+?>', '', text)
    #text = re.sub(r' x+', ' xx', text, flags=re.IGNORECASE)
    text = re.sub(r'[^a-zA-Z0-9 ]', ' ', text)
    text = re.sub(r'http\S+', ' ', text)  # Remove URLs
    text = re.sub(r'\d+', ' ', text)  # Remove numbers
    #text = re.sub(r'[^\w\s]', ' ', text)  # Remove punctuation
    text = re.sub(r'\n', ' ', text)  # Remove newline characters
    text = re.sub(' +', ' ', text)  # Replace multiple spaces with single space
    text = text.strip()
    return text

def word_overlap(target_text, candidate_text):
    #delimiters = r'[ ,!?;:/\-]+'
    # Tokenize the texts into words
    target_words = set(target_text.split())
    #target_words = set(re.split(delimiters, target_text))
    #candidate_words = set(re.split(delimiters, target_text))
    candidate_words = set(candidate_text.split())
    # Calculate the overlap as the number of common words
    overlap = len(target_words.intersection(candidate_words))
    return overlap


@app.get("/")
def read_root():
    return {"message": "Welcome to the SMS Embedding Service. Use the /embed/ endpoint to get embeddings."}


@app.get("/health")
def read_root():
    return {"message": "Ok"}

@app.post("/embedding-reranker")
def get_results(nn_neighbour_results: dict) -> dict:
    # nn_neighbour_results = json.loads(nn_neighbour_results)
    cosine_similarities = []
    word_overlaps = []
    top_n = 3
    target_vector = nn_neighbour_results['query_embedding']
    target_text = nn_neighbour_results['query_narration']
    target_text = clean_text_2(target_text)

    nn_neighbour_count = len(nn_neighbour_results['matched_metadata'])
    nn_sms_narration = list()

    for i in range(0, nn_neighbour_count):
        # Calculate cosine similarity
        cosine_dist = cosine(target_vector, nn_neighbour_results['matched_metadata'][i]['embedding'])
        cosine_distance = round((1 - cosine_dist) * 100, 2)
        cosine_similarities.append(cosine_distance)

        # Calculate word overlap
        raw_nn_sms_narration = json.loads(nn_neighbour_results['matched_metadata'][i]['metadata'])['sms_narration']
        nn_sms_narration.append(raw_nn_sms_narration)
        candidate_text = clean_text_2(raw_nn_sms_narration)
        overlap = word_overlap(target_text, candidate_text)
        word_overlaps.append(overlap)

    # Normalize word overlaps to the same scale as cosine similarity (0-100)
    max_overlap = max(word_overlaps) if word_overlaps else 1
    normalized_overlaps = [(100 * overlap / max_overlap) for overlap in word_overlaps]

    # Combine cosine similarity with word overlap
    combined_scores = [
        (0.85 * cosine_similarities[i]) + (0.15 * normalized_overlaps[i])
        for i in range(nn_neighbour_count)
    ]

    best_matches = np.argsort(combined_scores)[::-1][:top_n]

    data = []
    for i in best_matches:
        temp_dict = {}
        temp_dict['id'] = nn_neighbour_results['matched_metadata'][i]['id']
        temp_dict['score'] = round(combined_scores[i], 2)
        temp_dict['matched_sms_narration'] = nn_sms_narration[i]
        data.append(temp_dict)

    ranked_documents = {}
    ranked_documents['data'] = data

    return ranked_documents

#5. Run the API with uvicorn
#    Will run on http://127.0.0.1:8000
if __name__ == '__main__':
    uvicorn.run(app, host='127.0.0.1', port=8000, workers=4)